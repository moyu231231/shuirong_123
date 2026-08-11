/*
 * ACE mempatch / kpatch (no dylib) — 稳态 + 机型伪装（不注入）：
 *   0) DATA Tier2：COREREPORT 门闩
 *   A) GOT：OnRecv / rcv_anti_data → ret0
 *   S) 可写内存里改 iPhone*,* / 系统版本串 → iPhone18,1 + 26.6
 *   J) Dopamine 越狱时：尝试 jbclient 标记 debugged，再 task_for_pid 外部写
 *
 *   sy_mempatch <pid>
 *   sy_kpatch   <pid>   （同源 -DSY_AS_KPATCH）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld_images.h>
#include <sys/stat.h>
#include <time.h>
#include <stdbool.h>

#ifndef SY_AS_KPATCH
#define SY_AS_KPATCH 0
#endif

typedef vm_address_t raddr_t;
typedef vm_size_t rsize_t;

#define STATUS_PATH "/var/mobile/Library/Caches/sy_ports_status.txt"
#define PAGE_MASK   ((raddr_t)0x3FFFu)

/* File VAs from local tersafe v7.7.49.57576 (imagebase=0) */
#define RVA_TSS_GET_REPORT_DATA  0x1B6B8u
#define RVA_COREREPORT           0x3F284u
/* COREREPORT 入口读的 BSS 门闩（已 IDA/本地反汇编确认） */
#define RVA_TDM_ENABLED          0x2B8F58u  /* 0 → 直接走 return 0 */
#define RVA_TDM_CHECKED          0x2B8F59u  /* 1 → 跳过重新探测，沿用 enabled */

/* 最新画像（与原先 dylib 伪装目标一致，但走 mempatch 改串） */
static const char kWantMachine[] = "iPhone18,1"; /* 10 字节，与多数 iPhoneN,M 同长 */
static const char kWantOS[]      = "26.6";

static void write_status(const char *line) {
    mkdir("/var/mobile/Library/Caches", 0755);
    FILE *f = fopen(STATUS_PATH, "w");
    if (!f) f = fopen("/tmp/sy_ports_status.txt", "w");
    if (!f) return;
    fprintf(f, "%s\n", line);
    fclose(f);
}

/* Dopamine / rootless：存在 /var/jb 即视为已越狱 */
static int jailbreak_active(void) {
    struct stat st;
    if (stat("/var/jb", &st) == 0) return 1;
    if (stat("/var/jb/usr/lib", &st) == 0) return 1;
    const char *jr = getenv("JB_ROOT_PATH");
    if (jr && jr[0] && stat(jr, &st) == 0) return 1;
    return 0;
}

/*
 * 可选：通过 jbclient / libjailbreak 降低目标进程校验干扰。
 * 无库时静默跳过，仍走 task_for_pid。
 */
static void try_jb_prep(pid_t pid) {
    if (!jailbreak_active()) return;
    void *h = dlopen("/var/jb/basebin/libjailbreak.dylib", RTLD_LAZY);
    if (!h) h = dlopen("libjailbreak.dylib", RTLD_LAZY);
    if (!h) return;
    int (*set_dbg)(uint64_t, bool) =
        (int (*)(uint64_t, bool))dlsym(h, "jbclient_platform_set_process_debugged");
    int (*trust_path)(const char *) =
        (int (*)(const char *))dlsym(h, "jbclient_trust_file_by_path");
    if (trust_path) {
        trust_path("/var/jb/usr/local/shuiyong/sy_kpatch");
        trust_path("/var/mobile/Library/shuiyong/sy_kpatch");
    }
    if (set_dbg) {
        int r = set_dbg((uint64_t)pid, true);
        fprintf(stdout, "jb set_debugged pid=%d -> %d\n", (int)pid, r);
    }
}

static kern_return_t tread(task_t task, raddr_t addr, void *buf, rsize_t sz) {
    vm_size_t out = 0;
    return vm_read_overwrite(task, addr, sz, (vm_address_t)(uintptr_t)buf, &out);
}

static int twrite_raw(task_t task, raddr_t addr, const void *buf, rsize_t sz) {
    kern_return_t kr = vm_write(task, addr, (vm_offset_t)(uintptr_t)buf, (mach_msg_type_number_t)sz);
    return kr == KERN_SUCCESS ? 0 : -1;
}

typedef struct {
    raddr_t load;
    char path[512];
} remote_img_t;

static int load_images(task_t task, raddr_t all_info_addr,
                       remote_img_t **out_imgs, uint32_t *out_n) {
    struct dyld_all_image_infos infos;
    if (tread(task, all_info_addr, &infos, sizeof(infos)) != KERN_SUCCESS) return -1;
    if (!infos.infoArray || infos.infoArrayCount == 0 || infos.infoArrayCount > 4096) return -1;

    size_t arr_sz = sizeof(struct dyld_image_info) * infos.infoArrayCount;
    struct dyld_image_info *arr = (struct dyld_image_info *)malloc(arr_sz);
    if (!arr) return -1;
    if (tread(task, (raddr_t)(uintptr_t)infos.infoArray, arr, arr_sz) != KERN_SUCCESS) {
        free(arr);
        return -1;
    }

    remote_img_t *imgs = (remote_img_t *)calloc(infos.infoArrayCount, sizeof(remote_img_t));
    if (!imgs) { free(arr); return -1; }

    uint32_t n = 0;
    for (uint32_t i = 0; i < infos.infoArrayCount; i++) {
        if (!arr[i].imageLoadAddress) continue;
        imgs[n].load = (raddr_t)(uintptr_t)arr[i].imageLoadAddress;
        if (arr[i].imageFilePath) {
            tread(task, (raddr_t)(uintptr_t)arr[i].imageFilePath,
                  imgs[n].path, sizeof(imgs[n].path) - 1);
        }
        n++;
    }
    free(arr);
    *out_imgs = imgs;
    *out_n = n;
    return 0;
}

static int image_slide(task_t task, raddr_t image, raddr_t *out_slide) {
    struct mach_header_64 mh;
    if (tread(task, image, &mh, sizeof(mh)) != KERN_SUCCESS) return -1;
    if (mh.magic != MH_MAGIC_64) return -1;
    raddr_t lc = image + sizeof(mh);
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command cmd;
        if (tread(task, lc, &cmd, sizeof(cmd)) != KERN_SUCCESS) return -1;
        if (cmd.cmd == LC_SEGMENT_64) {
            struct segment_command_64 seg;
            tread(task, lc, &seg, sizeof(seg));
            if (strncmp(seg.segname, "__TEXT", 16) == 0) {
                *out_slide = image - seg.vmaddr;
                return 0;
            }
        }
        lc += cmd.cmdsize;
    }
    return -1;
}

static raddr_t remote_sym(task_t task, raddr_t image, const char *want) {
    struct mach_header_64 mh;
    if (tread(task, image, &mh, sizeof(mh)) != KERN_SUCCESS) return 0;
    if (mh.magic != MH_MAGIC_64) return 0;

    raddr_t lc = image + sizeof(mh);
    struct segment_command_64 linkedit = {0};
    struct symtab_command symtab = {0};
    raddr_t slide = 0;
    if (image_slide(task, image, &slide) != 0) return 0;

    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command cmd;
        if (tread(task, lc, &cmd, sizeof(cmd)) != KERN_SUCCESS) break;
        if (cmd.cmd == LC_SYMTAB) {
            tread(task, lc, &symtab, sizeof(symtab));
        } else if (cmd.cmd == LC_SEGMENT_64) {
            struct segment_command_64 seg;
            tread(task, lc, &seg, sizeof(seg));
            if (strncmp(seg.segname, "__LINKEDIT", 16) == 0) linkedit = seg;
        }
        lc += cmd.cmdsize;
    }
    if (!symtab.cmd || !linkedit.cmd) return 0;

    raddr_t base = linkedit.vmaddr + slide - linkedit.fileoff;
    char *strtbl = (char *)malloc(symtab.strsize);
    if (!strtbl) return 0;
    if (tread(task, base + symtab.stroff, strtbl, symtab.strsize) != KERN_SUCCESS) {
        free(strtbl);
        return 0;
    }

    char want2[256];
    snprintf(want2, sizeof(want2), "_%s", want);

    raddr_t hit = 0;
    for (uint32_t s = 0; s < symtab.nsyms; s++) {
        struct nlist_64 e;
        if (tread(task, base + symtab.symoff + sizeof(e) * s, &e, sizeof(e)) != KERN_SUCCESS)
            continue;
        if ((e.n_type & N_TYPE) != N_SECT) continue;
        if (e.n_un.n_strx == 0 || e.n_un.n_strx >= symtab.strsize) continue;
        const char *name = strtbl + e.n_un.n_strx;
        if (!strcmp(name, want) || !strcmp(name, want2)) {
            hit = e.n_value + slide;
            break;
        }
    }
    free(strtbl);
    return hit;
}

static int is_got_sect(const char *sectname) {
    return !strcmp(sectname, "__got")
        || !strcmp(sectname, "__la_symbol_ptr")
        || !strcmp(sectname, "__nl_symbol_ptr")
        || !strcmp(sectname, "__auth_got")
        || !strcmp(sectname, "__auth_ptr");
}

static int rewrite_slot(task_t task, raddr_t at, raddr_t stub) {
    raddr_t page = at & ~PAGE_MASK;
    vm_protect(task, page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    uint64_t nv = (uint64_t)stub;
    return twrite_raw(task, at, &nv, 8) == 0 ? 1 : 0;
}

/* A: GOT in OTHER images only */
static int rewrite_gots(task_t task, remote_img_t *imgs, uint32_t nimg,
                        raddr_t tersafe_base,
                        const raddr_t *targets, int nt,
                        raddr_t stub) {
    int hits = 0;
    uint8_t *chunk = (uint8_t *)malloc(0x4000);
    if (!chunk) return 0;

    for (uint32_t ii = 0; ii < nimg; ii++) {
        raddr_t image = imgs[ii].load;
        if (!image || image == tersafe_base) continue;

        struct mach_header_64 mh;
        if (tread(task, image, &mh, sizeof(mh)) != KERN_SUCCESS) continue;
        if (mh.magic != MH_MAGIC_64) continue;

        raddr_t slide = 0;
        if (image_slide(task, image, &slide) != 0) continue;

        raddr_t lc = image + sizeof(mh);
        for (uint32_t i = 0; i < mh.ncmds; i++) {
            struct load_command cmd;
            if (tread(task, lc, &cmd, sizeof(cmd)) != KERN_SUCCESS) break;
            if (cmd.cmd == LC_SEGMENT_64) {
                struct segment_command_64 seg;
                if (tread(task, lc, &seg, sizeof(seg)) != KERN_SUCCESS) {
                    lc += cmd.cmdsize;
                    continue;
                }
                if (seg.nsects == 0 || seg.nsects > 512) {
                    lc += cmd.cmdsize;
                    continue;
                }
                raddr_t sect_addr = lc + sizeof(struct segment_command_64);
                for (uint32_t s = 0; s < seg.nsects; s++) {
                    struct section_64 sect;
                    if (tread(task, sect_addr + sizeof(sect) * s, &sect, sizeof(sect)) != KERN_SUCCESS)
                        continue;
                    if (!is_got_sect(sect.sectname)) continue;
                    if (sect.size < 8 || sect.size > 8 * 1024 * 1024) continue;

                    raddr_t base = sect.addr + slide;
                    rsize_t off = 0;
                    while (off + 8 <= sect.size) {
                        rsize_t nread = sect.size - off;
                        if (nread > 0x4000) nread = 0x4000;
                        nread &= ~(rsize_t)7;
                        if (nread < 8) break;
                        if (tread(task, base + off, chunk, nread) != KERN_SUCCESS) {
                            off += nread;
                            continue;
                        }
                        for (rsize_t p = 0; p + 8 <= nread; p += 8) {
                            uint64_t v;
                            memcpy(&v, chunk + p, 8);
                            for (int t = 0; t < nt; t++) {
                                if (targets[t] && v == (uint64_t)targets[t])
                                    hits += rewrite_slot(task, base + off + p, stub);
                            }
                        }
                        off += nread;
                    }
                }
            }
            lc += cmd.cmdsize;
        }
    }
    free(chunk);
    return hits;
}

static raddr_t scan_text_ret0(task_t task, raddr_t image) {
    const uint32_t pat[2] = { 0xD2800000u, 0xD65F03C0u };
    uint8_t *chunk = (uint8_t *)malloc(0x4000);
    if (!chunk) return 0;

    struct mach_header_64 mh;
    if (tread(task, image, &mh, sizeof(mh)) != KERN_SUCCESS) { free(chunk); return 0; }
    if (mh.magic != MH_MAGIC_64) { free(chunk); return 0; }
    raddr_t slide = 0;
    if (image_slide(task, image, &slide) != 0) { free(chunk); return 0; }

    raddr_t lc = image + sizeof(mh);
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command cmd;
        if (tread(task, lc, &cmd, sizeof(cmd)) != KERN_SUCCESS) break;
        if (cmd.cmd == LC_SEGMENT_64) {
            struct segment_command_64 seg;
            tread(task, lc, &seg, sizeof(seg));
            if (strncmp(seg.segname, "__TEXT", 16) != 0) {
                lc += cmd.cmdsize;
                continue;
            }
            raddr_t sect_addr = lc + sizeof(struct segment_command_64);
            for (uint32_t s = 0; s < seg.nsects && s < 64; s++) {
                struct section_64 sect;
                if (tread(task, sect_addr + sizeof(sect) * s, &sect, sizeof(sect)) != KERN_SUCCESS)
                    continue;
                if (strcmp(sect.sectname, "__text") != 0) continue;
                if (sect.size < 8 || sect.size > 32 * 1024 * 1024) continue;
                raddr_t base = sect.addr + slide;
                rsize_t lim = sect.size > 0x100000 ? 0x100000 : (rsize_t)sect.size;
                for (rsize_t off = 0; off + 8 <= lim; ) {
                    rsize_t nread = lim - off;
                    if (nread > 0x4000) nread = 0x4000;
                    if (tread(task, base + off, chunk, nread) != KERN_SUCCESS) break;
                    for (rsize_t q = 0; q + 8 <= nread; q += 4) {
                        uint32_t a, b;
                        memcpy(&a, chunk + q, 4);
                        memcpy(&b, chunk + q + 4, 4);
                        if (a == pat[0] && b == pat[1]) {
                            free(chunk);
                            return base + off + q;
                        }
                    }
                    off += (nread > 4) ? (nread - 4) : nread;
                }
            }
        }
        lc += cmd.cmdsize;
    }
    free(chunk);
    return 0;
}

/* Prefer gadget inside tersafe (同镜像，少跨库痕迹)，再退系统库 */
static raddr_t find_ret0_gadget(task_t task, remote_img_t *imgs, uint32_t nimg,
                                raddr_t tersafe) {
    if (tersafe) {
        raddr_t g = scan_text_ret0(task, tersafe);
        if (g) return g;
    }
    for (uint32_t ii = 0; ii < nimg; ii++) {
        const char *p = imgs[ii].path;
        if (!strstr(p, "libsystem") && !strstr(p, "libdyld") &&
            !strstr(p, "libobjc") && !strstr(p, "/usr/lib/"))
            continue;
        raddr_t g = scan_text_ret0(task, imgs[ii].load);
        if (g) return g;
    }
    return 0;
}

static raddr_t resolve_slide(task_t task, raddr_t tersafe, raddr_t anchor_sym) {
    raddr_t slide = 0;
    image_slide(task, tersafe, &slide);
    if (anchor_sym) {
        raddr_t from_sym = anchor_sym - RVA_TSS_GET_REPORT_DATA;
        if (slide && from_sym != slide) {
            fprintf(stdout, "slide warn: dyld=0x%llx sym=0x%llx (use sym)\n",
                    (unsigned long long)slide, (unsigned long long)from_sym);
        }
        slide = from_sym;
    }
    return slide;
}

/* 本地 v7.7.49.57576 COREREPORT 入口前 4 条指令（写 BSS 前必须对上） */
static int corereport_version_ok(task_t task, raddr_t slide) {
    static const uint32_t expect[4] = {
        0xA9BC5FF8u, 0xA90157F6u, 0xA9024FF4u, 0xA9037BFDu
    };
    uint32_t w[4] = {0};
    raddr_t addr = slide + RVA_COREREPORT;
    if (tread(task, addr, w, sizeof(w)) != KERN_SUCCESS) {
        fprintf(stdout, "flag skip: cannot read COREREPORT @ 0x%llx\n",
                (unsigned long long)addr);
        return 0;
    }
    if (memcmp(w, expect, sizeof(expect)) != 0) {
        fprintf(stdout, "flag skip: COREREPORT mismatch @ 0x%llx  %08x %08x %08x %08x\n",
                (unsigned long long)addr, w[0], w[1], w[2], w[3]);
        return 0;
    }
    return 1;
}

/*
 * Tier2 DATA：enabled=0 + checked=1
 * COREREPORT 见 0x3F2AC..0x3F2C0：checked 置位且 enabled==0 → 直接 return 0
 */
static int patch_tdm_flags(task_t task, raddr_t slide) {
    if (!corereport_version_ok(task, slide)) return 0;

    raddr_t en = slide + RVA_TDM_ENABLED;
    raddr_t ck = slide + RVA_TDM_CHECKED;
    uint8_t cur[2] = {0xFF, 0xFF};
    if (tread(task, en, cur, 2) != KERN_SUCCESS) {
        fprintf(stdout, "flag read fail @ 0x%llx\n", (unsigned long long)en);
        return 0;
    }
    uint8_t want[2] = { 0x00, 0x01 };
    raddr_t page = en & ~PAGE_MASK;
    vm_protect(task, page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (twrite_raw(task, en, want, 2) != 0) {
        fprintf(stdout, "flag write fail @ 0x%llx (was %02x %02x)\n",
                (unsigned long long)en, cur[0], cur[1]);
        return 0;
    }
    uint8_t verify[2] = {0xFF, 0xFF};
    tread(task, en, verify, 2);
    fprintf(stdout, "flag ok @ 0x%llx/%llx  %02x%02x -> %02x%02x\n",
            (unsigned long long)en, (unsigned long long)ck,
            cur[0], cur[1], verify[0], verify[1]);
    return (verify[0] == 0x00 && verify[1] == 0x01) ? 1 : 0;
}

/* 判断是否为 iPhoneN,M 产品型号串（NUL 结尾或后接非数字） */
static int is_iphone_product(const char *s, size_t avail, size_t *out_len) {
    if (avail < 8 || memcmp(s, "iPhone", 6) != 0) return 0;
    size_t i = 6;
    if (i >= avail || s[i] < '0' || s[i] > '9') return 0;
    while (i < avail && s[i] >= '0' && s[i] <= '9') i++;
    if (i >= avail || s[i] != ',') return 0;
    i++;
    if (i >= avail || s[i] < '0' || s[i] > '9') return 0;
    while (i < avail && s[i] >= '0' && s[i] <= '9') i++;
    /* 必须以 \0 结束，避免误伤更长串 */
    if (i >= avail || s[i] != '\0') return 0;
    if (out_len) *out_len = i;
    return 1;
}

static int spoof_replace_machine(task_t task, raddr_t at, const char *old, size_t old_len) {
    if (!strcmp(old, kWantMachine)) return 0;
    char buf[32];
    size_t want_len = strlen(kWantMachine);
    if (old_len < want_len) return 0; /* 放不下 */
    memset(buf, 0, sizeof(buf));
    memcpy(buf, kWantMachine, want_len);
    /* 保持原长度：多余字节填 0，避免破坏相邻字段 */
    raddr_t page = at & ~PAGE_MASK;
    vm_protect(task, page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (twrite_raw(task, at, buf, old_len + 1) != 0) /* 含一个 NUL */
        return twrite_raw(task, at, buf, old_len) == 0 ? 1 : 0;
    return 1;
}

static int spoof_replace_os(task_t task, raddr_t at, size_t old_len) {
    size_t want_len = strlen(kWantOS);
    if (old_len < want_len) return 0;
    char buf[16];
    memset(buf, 0, sizeof(buf));
    memcpy(buf, kWantOS, want_len);
    raddr_t page = at & ~PAGE_MASK;
    vm_protect(task, page, 0x4000, FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    return twrite_raw(task, at, buf, old_len) == 0 ? 1 : 0;
}

/*
 * 在可写内存中改已缓存的机型/系统串（无 dylib）。
 * 只扫 RW 区域，不碰 RX TEXT。
 */
static int spoof_device_strings(task_t task) {
    int hits = 0;
    uint8_t *chunk = (uint8_t *)malloc(0x4000);
    if (!chunk) return 0;

    raddr_t addr = 0;
    raddr_t scanned = 0;
    const raddr_t scan_cap = 96 * 1024 * 1024; /* 最多扫约 96MB 可写区 */

    while (scanned < scan_cap) {
        vm_address_t vaddr = (vm_address_t)addr;
        vm_size_t vsize = 0;
        natural_t depth = 0;
        struct vm_region_basic_info_64 info;
        mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        kern_return_t kr = vm_region_64(task, &vaddr, &vsize, VM_REGION_BASIC_INFO_64,
                                        (vm_region_info_t)&info, &count, &obj);
        if (kr != KERN_SUCCESS) break;
        if (MACH_PORT_VALID(obj)) mach_port_deallocate(mach_task_self(), obj);

        raddr_t base = (raddr_t)vaddr;
        raddr_t next = base + (raddr_t)vsize;
        int writable = (info.protection & VM_PROT_WRITE) != 0
                    || (info.max_protection & VM_PROT_WRITE) != 0;
        if (writable && vsize > 0 && vsize < 64 * 1024 * 1024) {
            rsize_t off = 0;
            while (off + 16 <= (rsize_t)vsize && scanned < scan_cap) {
                rsize_t nread = (rsize_t)vsize - off;
                if (nread > 0x4000) nread = 0x4000;
                if (tread(task, base + off, chunk, nread) != KERN_SUCCESS) {
                    off += nread;
                    scanned += nread;
                    continue;
                }
                for (rsize_t i = 0; i + 8 < nread; i++) {
                    size_t plen = 0;
                    if (is_iphone_product((const char *)chunk + i, nread - i, &plen)) {
                        char cur[24];
                        if (plen >= sizeof(cur)) continue;
                        memcpy(cur, chunk + i, plen);
                        cur[plen] = 0;
                        if (spoof_replace_machine(task, base + off + i, cur, plen)) {
                            hits++;
                            fprintf(stdout, "spoof machine %s -> %s @ 0x%llx\n",
                                    cur, kWantMachine, (unsigned long long)(base + off + i));
                            i += plen;
                        }
                        continue;
                    }
                    /* 仅改 X.Y.Z 形态（避免误伤 "16.0" 等短串） */
                    static const char *old_os[] = {
                        "15.4.1", "15.5.1", "15.6.1", "15.7.1", "15.8.1", "15.8.2", "15.8.3",
                        "16.0.1", "16.1.1", "16.1.2", "16.2.1", "16.3.1", "16.4.1", "16.5.1", "16.6.1", "16.7.1", "16.7.2",
                        "17.0.1", "17.1.1", "17.2.1", "17.3.1", "17.4.1", "17.5.1", "17.6.1",
                        "18.0.1", "18.1.1", "18.2.1", "18.3.1", "18.4.1", "18.5.1",
                        NULL
                    };
                    for (int o = 0; old_os[o]; o++) {
                        size_t ol = strlen(old_os[o]);
                        if (i + ol > nread) continue;
                        if (memcmp(chunk + i, old_os[o], ol) != 0) continue;
                        /* 必须是独立 C 串 */
                        if (i + ol < nread && chunk[i + ol] != 0) continue;
                        if (spoof_replace_os(task, base + off + i, ol)) {
                            hits++;
                            fprintf(stdout, "spoof os %s -> %s @ 0x%llx\n",
                                    old_os[o], kWantOS, (unsigned long long)(base + off + i));
                        }
                        break;
                    }
                }
                off += nread;
                scanned += nread;
            }
        }
        if (next <= addr) break;
        addr = next;
    }

    free(chunk);
    fprintf(stdout, "spoof_hits=%d scanned≈%lluKB\n",
            hits, (unsigned long long)(scanned / 1024));
    return hits;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <pid>\n", SY_AS_KPATCH ? "sy_kpatch" : "sy_mempatch");
        return 1;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    if (pid <= 1) {
        fprintf(stderr, "bad pid\n");
        return 1;
    }

    int jb = jailbreak_active();
    fprintf(stdout, "jb=%d tool=%s\n", jb, SY_AS_KPATCH ? "kpatch" : "mempatch");
    try_jb_prep(pid);

    task_t task = MACH_PORT_NULL;
    kern_return_t kr = task_for_pid(mach_task_self(), pid, &task);
    if (kr != KERN_SUCCESS || !MACH_PORT_VALID(task)) {
        fprintf(stderr, "task_for_pid failed: %s\n", mach_error_string(kr));
        write_status("FAIL task_for_pid");
        return 2;
    }

    task_dyld_info_data_t dyld;
    mach_msg_type_number_t cnt = TASK_DYLD_INFO_COUNT;
    kr = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld, &cnt);
    if (kr != KERN_SUCCESS) {
        write_status("FAIL dyld_info");
        return 3;
    }

    remote_img_t *imgs = NULL;
    uint32_t nimg = 0;
    raddr_t tersafe = 0;

    for (int t = 0; t < 40; t++) {
        free(imgs);
        imgs = NULL;
        nimg = 0;
        if (load_images(task, (raddr_t)dyld.all_image_info_addr, &imgs, &nimg) != 0) {
            sleep(1);
            continue;
        }
        for (uint32_t i = 0; i < nimg; i++) {
            if (strstr(imgs[i].path, "tersafe") || strstr(imgs[i].path, "Tersafe")) {
                tersafe = imgs[i].load;
                fprintf(stdout, "tersafe: %s @ 0x%llx\n", imgs[i].path, (unsigned long long)tersafe);
                break;
            }
        }
        if (tersafe) break;
        sleep(1);
    }
    if (!tersafe) {
        write_status("FAIL no_tersafe");
        free(imgs);
        mach_port_deallocate(mach_task_self(), task);
        return 4;
    }

    /* 仅用于算 slide；GOT 不改 GetReport（ret0→NULL 易空指针闪退） */
    raddr_t anchor = remote_sym(task, tersafe, "tss_get_report_data");
    if (!anchor) anchor = remote_sym(task, tersafe, "TssSDKGetReportData");
    if (!anchor) {
        write_status("FAIL no_syms");
        free(imgs);
        mach_port_deallocate(mach_task_self(), task);
        return 5;
    }
    fprintf(stdout, "sym anchor @ 0x%llx\n", (unsigned long long)anchor);

    /* GOT 只挡检测下发（返回 int） */
    static const char *got_syms[] = {
        "TssSDKOnRecvData", "tss_sdk_rcv_anti_data", NULL
    };
    raddr_t addrs[8];
    int naddr = 0;
    memset(addrs, 0, sizeof(addrs));
    for (int i = 0; got_syms[i] && naddr < 8; i++) {
        raddr_t a = remote_sym(task, tersafe, got_syms[i]);
        if (!a) {
            fprintf(stdout, "miss %s\n", got_syms[i]);
            continue;
        }
        fprintf(stdout, "sym %s @ 0x%llx\n", got_syms[i], (unsigned long long)a);
        addrs[naddr++] = a;
    }

    raddr_t slide = resolve_slide(task, tersafe, anchor);
    fprintf(stdout, "slide=0x%llx\n", (unsigned long long)slide);

    raddr_t stub = find_ret0_gadget(task, imgs, nimg, tersafe);
    fprintf(stdout, "stub @ 0x%llx\n", (unsigned long long)stub);

    int got_hits = 0;
    if (stub && naddr > 0) {
        got_hits = rewrite_gots(task, imgs, nimg, tersafe, addrs, naddr, stub);
    } else {
        fprintf(stdout, "got skipped\n");
    }
    fprintf(stdout, "got_rewrites=%d\n", got_hits);

    /* 不 suspend：减少卡死/异常；只写 DATA 门闩，零 TEXT */
    int flag_ok = patch_tdm_flags(task, slide);
    fprintf(stdout, "flag=%d got=%d\n", flag_ok, got_hits);

    /* 可写区改机型/系统串（无 dylib） */
    int spoof_hits = spoof_device_strings(task);
    fprintf(stdout, "spoof=%d target=%s/%s\n", spoof_hits, kWantMachine, kWantOS);

    free(imgs);
    mach_port_deallocate(mach_task_self(), task);

    char buf[320];
    if (flag_ok > 0 || got_hits > 0 || spoof_hits > 0) {
        snprintf(buf, sizeof(buf),
                 "OK mempatch flag=%d got=%d spoof=%d jb=%d recv=0 report=0 leaf=0 syms=%d pid=%d time=%ld",
                 flag_ok, got_hits, spoof_hits, jb, naddr, (int)pid, (long)time(NULL));
        write_status(buf);
        fprintf(stdout, "%s\n", buf);
        return 0;
    }

    snprintf(buf, sizeof(buf),
             "FAIL mempatch flag=0 got=0 spoof=0 jb=%d syms=%d",
             jb, naddr);
    write_status(buf);
    fprintf(stdout, "%s\n", buf);
    return 8;
}
