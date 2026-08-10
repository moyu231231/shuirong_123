/*
 * ACE mempatch (no dylib) — 针对「局内过一会踢」：
 *   0) DATA Tier2：COREREPORT 门闩 byte@0x2B8F58=0 / 0x2B8F59=1
 *      （对标 ACE-ANTICHEAT g_tdm_report_enabled / checked，不改 TEXT）
 *   A) GOT → tersafe/系统内现成 MOV X0,#0;RET（不造匿名 RX）
 *   B) TEXT ret0：OnRecv / rcv_anti_data / OnRecvSignature（挡检测下发）
 *   C) TEXT ret0：TssSDKGetReportData* 薄导出（挡游戏轮询夹带 send_gs）
 *   不做：COREREPORT TEXT、总闸、匿名页、全量 DATA 指针扫
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

static int twrite_code(task_t task, raddr_t addr, const void *buf, rsize_t sz) {
    raddr_t page = addr & ~PAGE_MASK;
    rsize_t span = ((addr - page) + sz + PAGE_MASK) & ~PAGE_MASK;
    kern_return_t kr = vm_protect(task, page, span, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        kr = vm_protect(task, page, span, FALSE,
                        VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) return -1;
    if (twrite_raw(task, addr, buf, sz) != 0) return -2;
    vm_protect(task, page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return 0;
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

static int patch_ret0(task_t task, raddr_t addr) {
    uint32_t code[2] = { 0xD2800000u, 0xD65F03C0u };
    return twrite_code(task, addr, code, sizeof(code));
}

static int looks_like_func_prologue(const uint32_t *w) {
    if (w[0] == 0xD2800000u && w[1] == 0xD65F03C0u) return 2;
    uint32_t op = w[0];
    if (op == 0 || op == 0xFFFFFFFFu) return 0;
    if ((op & 0xFFE00000u) == 0xD4200000u) return 0;
    if ((op & 0xFFC00000u) == 0xA9000000u) return 1;
    if ((op & 0xFFC00000u) == 0xA9800000u) return 1;
    if ((op & 0xFFC003FFu) == 0xD10003FFu) return 1;
    if (op == 0xD503237Fu) return 1;
    if ((op & 0xFFE0FFE0u) == 0xAA0003E0u) return 1;
    if ((op & 0xFF000000u) == 0xD1000000u) return 1;
    if ((op & 0xFF000000u) == 0xF9000000u) return 1;
    if ((op & 0x9F000000u) == 0x90000000u) return 1;
    if ((op & 0x7E000000u) == 0x34000000u) return 1;
    if ((op & 0xFC000000u) == 0x14000000u) return 1;
    if ((op & 0xFC000000u) == 0x94000000u) return 1;
    if ((op & 0xFF800000u) == 0xD2800000u) return 1;
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

/*
 * Tier2 DATA：enabled=0 + checked=1
 * COREREPORT 见 0x3F2AC..0x3F2C0：checked 置位且 enabled==0 → 直接 return 0
 */
static int patch_tdm_flags(task_t task, raddr_t slide) {
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

static int patch_syms_ret0(task_t task, raddr_t tersafe, const char **names, const char *tag) {
    int ok = 0;
    for (int i = 0; names[i]; i++) {
        raddr_t a = remote_sym(task, tersafe, names[i]);
        if (!a) {
            fprintf(stdout, "%s miss %s\n", tag, names[i]);
            continue;
        }
        uint32_t w[2] = {0, 0};
        if (tread(task, a, w, sizeof(w)) != KERN_SUCCESS) continue;
        int kind = looks_like_func_prologue(w);
        if (kind == 0) {
            fprintf(stdout, "%s skip %s bad prologue %08x %08x\n",
                    tag, names[i], w[0], w[1]);
            continue;
        }
        if (kind == 2 || patch_ret0(task, a) == 0) {
            ok++;
            fprintf(stdout, "%s ok %s @ 0x%llx\n", tag, names[i], (unsigned long long)a);
        } else {
            fprintf(stdout, "%s fail %s @ 0x%llx\n", tag, names[i], (unsigned long long)a);
        }
    }
    return ok;
}

/* 仅当 DATA 门闩失败时，才退回 COREREPORT TEXT */
static int patch_corereport_text_fallback(task_t task, raddr_t slide) {
    raddr_t addr = slide + RVA_COREREPORT;
    uint32_t w[2] = {0, 0};
    if (tread(task, addr, w, sizeof(w)) != KERN_SUCCESS) return 0;
    int kind = looks_like_func_prologue(w);
    if (kind == 0) {
        fprintf(stdout, "leaf skip COREREPORT prologue=%08x %08x\n", w[0], w[1]);
        return 0;
    }
    if (kind == 2 || patch_ret0(task, addr) == 0) {
        fprintf(stdout, "leaf ok COREREPORT @ 0x%llx (fallback)\n", (unsigned long long)addr);
        return 1;
    }
    return 0;
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

    static const char *syms[] = {
        "tss_get_report_data", "tss_get_report_data2",
        "tss_get_report_data3", "tss_get_report_data4",
        "TssSDKGetReportData", "TssSDKGetReportData2",
        "TssSDKGetReportData3", "TssSDKGetReportData4",
        "TssSDKOnRecvData", "TssSDKOnRecvSignature",
        "tss_sdk_rcv_anti_data",
        NULL
    };

    raddr_t addrs[24];
    int naddr = 0;
    raddr_t anchor = 0;
    memset(addrs, 0, sizeof(addrs));
    for (int i = 0; syms[i] && naddr < 24; i++) {
        raddr_t a = remote_sym(task, tersafe, syms[i]);
        if (!a) {
            fprintf(stdout, "miss %s\n", syms[i]);
            continue;
        }
        fprintf(stdout, "sym %s @ 0x%llx\n", syms[i], (unsigned long long)a);
        if (!strcmp(syms[i], "tss_get_report_data")) anchor = a;
        addrs[naddr++] = a;
    }
    if (naddr == 0) {
        write_status("FAIL no_syms");
        free(imgs);
        mach_port_deallocate(mach_task_self(), task);
        return 5;
    }

    raddr_t slide = resolve_slide(task, tersafe, anchor);
    fprintf(stdout, "slide=0x%llx\n", (unsigned long long)slide);

    raddr_t stub = find_ret0_gadget(task, imgs, nimg, tersafe);
    fprintf(stdout, "stub @ 0x%llx\n", (unsigned long long)stub);

    int got_hits = 0;
    if (stub) {
        got_hits = rewrite_gots(task, imgs, nimg, tersafe, addrs, naddr, stub);
    } else {
        fprintf(stdout, "got skipped (no gadget)\n");
    }
    fprintf(stdout, "got_rewrites=%d\n", got_hits);

    task_suspend(task);

    /* 0) DATA 门闩先打：上报汇聚直接空返回（延迟踢主因） */
    int flag_ok = patch_tdm_flags(task, slide);

    /* B) 检测下发 */
    static const char *recv_syms[] = {
        "TssSDKOnRecvData", "tss_sdk_rcv_anti_data", "TssSDKOnRecvSignature",
        NULL
    };
    int recv_ok = patch_syms_ret0(task, tersafe, recv_syms, "recv");

    /* C) 取报告薄导出：游戏轮询后 send_gs 夹带 */
    static const char *report_syms[] = {
        "TssSDKGetReportData", "TssSDKGetReportData2",
        "TssSDKGetReportData3", "TssSDKGetReportData4",
        NULL
    };
    int report_ok = patch_syms_ret0(task, tersafe, report_syms, "report");

    /* DATA 失败才 TEXT COREREPORT（增加 bin_patch 暴露） */
    int leaf_ok = 0;
    if (!flag_ok) {
        leaf_ok = patch_corereport_text_fallback(task, slide);
    }

    /* 再写一次门闩，防中间路径回写 */
    if (flag_ok) {
        flag_ok = patch_tdm_flags(task, slide);
    }

    fprintf(stdout, "flag=%d recv=%d report=%d leaf=%d got=%d\n",
            flag_ok, recv_ok, report_ok, leaf_ok, got_hits);

    task_resume(task);

    free(imgs);
    mach_port_deallocate(mach_task_self(), task);

    char buf[280];
    if (flag_ok > 0 || got_hits > 0 || recv_ok > 0 || report_ok > 0 || leaf_ok > 0) {
        snprintf(buf, sizeof(buf),
                 "OK mempatch flag=%d got=%d recv=%d report=%d leaf=%d syms=%d pid=%d time=%ld",
                 flag_ok, got_hits, recv_ok, report_ok, leaf_ok, naddr, (int)pid, (long)time(NULL));
        write_status(buf);
        fprintf(stdout, "%s\n", buf);
        return 0;
    }

    snprintf(buf, sizeof(buf),
             "FAIL mempatch flag=0 got=0 recv=0 report=0 leaf=0 syms=%d",
             naddr);
    write_status(buf);
    fprintf(stdout, "%s\n", buf);
    return 8;
}
