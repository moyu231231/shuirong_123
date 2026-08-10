/*
 * ACE mempatch (no dylib) — 稳态版（避免闪退）：
 *   0) DATA Tier2：COREREPORT 门闩 0x2B8F58=0 / 0x2B8F59=1
 *      写前校验 COREREPORT 入口机器码，版本不对则跳过（防写错 BSS）
 *   A) GOT：仅 OnRecv / rcv_anti_data → ret0（int 返回，不会空指针解引用）
 *   不做任何 TEXT 补丁：GetReport/COREREPORT/OnRecv TEXT 都曾导致闪退或自杀
 *   不做：匿名 RX、总闸、全量 DATA 指针扫
 *
 *   sy_mempatch <pid>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld_images.h>
#include <sys/stat.h>
#include <time.h>

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

static void write_status(const char *line) {
    mkdir("/var/mobile/Library/Caches", 0755);
    FILE *f = fopen(STATUS_PATH, "w");
    if (!f) f = fopen("/tmp/sy_ports_status.txt", "w");
    if (!f) return;
    fprintf(f, "%s\n", line);
    fclose(f);
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

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: sy_mempatch <pid>\n");
        return 1;
    }
    pid_t pid = (pid_t)atoi(argv[1]);
    if (pid <= 1) {
        fprintf(stderr, "bad pid\n");
        return 1;
    }

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

    free(imgs);
    mach_port_deallocate(mach_task_self(), task);

    char buf[240];
    if (flag_ok > 0 || got_hits > 0) {
        snprintf(buf, sizeof(buf),
                 "OK mempatch flag=%d got=%d recv=0 report=0 leaf=0 syms=%d pid=%d time=%ld",
                 flag_ok, got_hits, naddr, (int)pid, (long)time(NULL));
        write_status(buf);
        fprintf(stdout, "%s\n", buf);
        return 0;
    }

    snprintf(buf, sizeof(buf),
             "FAIL mempatch flag=0 got=0 syms=%d",
             naddr);
    write_status(buf);
    fprintf(stdout, "%s\n", buf);
    return 8;
}
