/*
 * Pure-local ACE mempatch (no dylib, no network dependency):
 *   A) rewrite other images' GOT/lazy slots -> ret0 gadget
 *   B) rewrite tersafe __DATA* pointers to report/recv exports -> stub
 *   C) leaf TEXT RET on COREREPORT / TDM / shell_report RVAs
 *      (tersafe v7.7.49.57576; prologue check; never touch 0x10E36C)
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

/* File VAs from IDA (imagebase=0), tersafe v7.7.49.57576 */
#define RVA_TSS_GET_REPORT_DATA  0x1B6B8u
#define RVA_COREREPORT           0x3F284u
#define RVA_TDM_REPORT           0x3E720u
#define RVA_COREREPORT_ROUTE     0x3F48Cu
#define RVA_SHELL_REPORT         0x100A20u

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

static int is_tersafe_data_seg(const char *segname) {
    return strncmp(segname, "__DATA", 6) == 0
        || strncmp(segname, "__AUTH_CONST", 12) == 0
        || strncmp(segname, "__DATA_CONST", 12) == 0;
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

/* B: tersafe DATA only — retarget pointers to report/recv exports */
static int rewrite_tersafe_data_ptrs(task_t task, raddr_t tersafe,
                                     const raddr_t *targets, int nt,
                                     raddr_t stub) {
    int hits = 0;
    uint8_t *chunk = (uint8_t *)malloc(0x4000);
    if (!chunk) return 0;

    struct mach_header_64 mh;
    if (tread(task, tersafe, &mh, sizeof(mh)) != KERN_SUCCESS) { free(chunk); return 0; }
    if (mh.magic != MH_MAGIC_64) { free(chunk); return 0; }

    raddr_t slide = 0;
    if (image_slide(task, tersafe, &slide) != 0) { free(chunk); return 0; }

    raddr_t lc = tersafe + sizeof(mh);
    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command cmd;
        if (tread(task, lc, &cmd, sizeof(cmd)) != KERN_SUCCESS) break;
        if (cmd.cmd == LC_SEGMENT_64) {
            struct segment_command_64 seg;
            if (tread(task, lc, &seg, sizeof(seg)) != KERN_SUCCESS) {
                lc += cmd.cmdsize;
                continue;
            }
            if (!is_tersafe_data_seg(seg.segname)) {
                lc += cmd.cmdsize;
                continue;
            }
            if (seg.vmsize < 8 || seg.vmsize > 64 * 1024 * 1024) {
                lc += cmd.cmdsize;
                continue;
            }

            raddr_t seg_addr = seg.vmaddr + slide;
            rsize_t off = 0;
            while (off + 8 <= seg.vmsize) {
                rsize_t nread = seg.vmsize - off;
                if (nread > 0x4000) nread = 0x4000;
                nread &= ~(rsize_t)7;
                if (nread < 8) break;
                if (tread(task, seg_addr + off, chunk, nread) != KERN_SUCCESS) {
                    off += nread;
                    continue;
                }
                for (rsize_t p = 0; p + 8 <= nread; p += 8) {
                    uint64_t v;
                    memcpy(&v, chunk + p, 8);
                    for (int t = 0; t < nt; t++) {
                        if (!targets[t] || v != (uint64_t)targets[t]) continue;
                        /* never rewrite a pointer that sits on the export itself */
                        raddr_t at = seg_addr + off + p;
                        if (at >= targets[t] && at < targets[t] + 16) continue;
                        hits += rewrite_slot(task, at, stub);
                    }
                }
                off += nread;
            }
        }
        lc += cmd.cmdsize;
    }
    free(chunk);
    return hits;
}

/* Prefer existing MOV X0,#0; RET in system libs */
static raddr_t find_ret0_gadget(task_t task, remote_img_t *imgs, uint32_t nimg) {
    const uint32_t pat[2] = { 0xD2800000u, 0xD65F03C0u };
    uint8_t *chunk = (uint8_t *)malloc(0x4000);
    if (!chunk) return 0;

    for (uint32_t ii = 0; ii < nimg; ii++) {
        const char *p = imgs[ii].path;
        if (!strstr(p, "libsystem") && !strstr(p, "libdyld") &&
            !strstr(p, "libobjc") && !strstr(p, "/usr/lib/"))
            continue;

        raddr_t image = imgs[ii].load;
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
                    rsize_t lim = sect.size > 0x80000 ? 0x80000 : (rsize_t)sect.size;
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
    }
    free(chunk);
    return 0;
}

static int patch_ret0(task_t task, raddr_t addr) {
    uint32_t code[2] = { 0xD2800000u, 0xD65F03C0u };
    return twrite_code(task, addr, code, sizeof(code));
}

/*
 * C: leaf report sinks only. Skip if prologue looks wrong (version mismatch)
 * or already patched. Never patch get_report* exports or master gate.
 */
static int looks_like_func_prologue(const uint32_t *w) {
    /* already our stub */
    if (w[0] == 0xD2800000u && w[1] == 0xD65F03C0u) return 2;
    uint32_t op = w[0];
    /* reject empty / padding / BRK — likely wrong RVA / version */
    if (op == 0 || op == 0xFFFFFFFFu) return 0;
    if ((op & 0xFFE00000u) == 0xD4200000u) return 0; /* BRK */
    /* common ARM64 openings (STP 64-bit is 0xA9......) */
    if ((op & 0xFFC00000u) == 0xA9000000u) return 1; /* STP */
    if ((op & 0xFFC00000u) == 0xA9800000u) return 1; /* STP pre */
    if ((op & 0xFFC003FFu) == 0xD10003FFu) return 1; /* SUB SP */
    if (op == 0xD503237Fu) return 1;                 /* PACIBSP */
    if ((op & 0xFFE0FFE0u) == 0xAA0003E0u) return 1; /* MOV */
    if ((op & 0xFF000000u) == 0xD1000000u) return 1; /* SUB imm */
    if ((op & 0xFF000000u) == 0xF9000000u) return 1; /* STR */
    if ((op & 0x9F000000u) == 0x90000000u) return 1; /* ADRP */
    if ((op & 0x7E000000u) == 0x34000000u) return 1; /* CBZ/CBNZ */
    if ((op & 0xFC000000u) == 0x14000000u) return 1; /* B */
    if ((op & 0xFC000000u) == 0x94000000u) return 1; /* BL */
    if ((op & 0xFF800000u) == 0xD2800000u) return 1; /* MOVZ */
    return 0;
}

static int patch_leaf_rvas(task_t task, raddr_t tersafe, raddr_t slide_hint,
                           raddr_t anchor_sym_addr) {
    static const struct { uint32_t rva; const char *name; } leaves[] = {
        { RVA_COREREPORT,       "COREREPORT" },
        { RVA_TDM_REPORT,       "TDM_REPORT" },
        { RVA_COREREPORT_ROUTE, "COREREPORT_ROUTE" },
        { RVA_SHELL_REPORT,     "shell_report" },
    };

    raddr_t slide = slide_hint;
    if (anchor_sym_addr) {
        raddr_t from_sym = anchor_sym_addr - RVA_TSS_GET_REPORT_DATA;
        if (slide && from_sym != slide) {
            fprintf(stdout, "slide warn: dyld=0x%llx sym=0x%llx (use sym)\n",
                    (unsigned long long)slide, (unsigned long long)from_sym);
        }
        slide = from_sym;
    }
    if (!slide) {
        if (image_slide(task, tersafe, &slide) != 0) return 0;
    }

    int ok = 0;
    for (size_t i = 0; i < sizeof(leaves) / sizeof(leaves[0]); i++) {
        /* IDA imagebase=0 RVA + slide (= anchor - known export RVA) */
        raddr_t addr = (raddr_t)leaves[i].rva + slide;

        uint32_t w[2] = {0, 0};
        if (tread(task, addr, w, sizeof(w)) != KERN_SUCCESS) {
            fprintf(stdout, "leaf miss read %s @ 0x%llx\n",
                    leaves[i].name, (unsigned long long)addr);
            continue;
        }
        int kind = looks_like_func_prologue(w);
        if (kind == 0) {
            fprintf(stdout, "leaf skip %s @ 0x%llx prologue=%08x %08x\n",
                    leaves[i].name, (unsigned long long)addr, w[0], w[1]);
            continue;
        }
        if (kind == 2) {
            fprintf(stdout, "leaf already %s\n", leaves[i].name);
            ok++;
            continue;
        }
        if (patch_ret0(task, addr) == 0) {
            fprintf(stdout, "leaf ok %s @ 0x%llx\n",
                    leaves[i].name, (unsigned long long)addr);
            ok++;
        } else {
            fprintf(stdout, "leaf fail %s @ 0x%llx\n",
                    leaves[i].name, (unsigned long long)addr);
        }
    }
    return ok;
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
        "TssSDKOnRecvData", "tss_sdk_rcv_anti_data",
        NULL
    };

    raddr_t addrs[16];
    int naddr = 0;
    raddr_t anchor = 0;
    memset(addrs, 0, sizeof(addrs));
    for (int i = 0; syms[i] && naddr < 16; i++) {
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

    raddr_t stub = find_ret0_gadget(task, imgs, nimg);
    int stub_anon = 0;
    if (!stub) {
        kr = vm_allocate(task, &stub, 0x4000, VM_FLAGS_ANYWHERE);
        if (kr != KERN_SUCCESS || !stub) {
            write_status("FAIL alloc_stub");
            free(imgs);
            mach_port_deallocate(mach_task_self(), task);
            return 6;
        }
        uint32_t stubcode[2] = { 0xD2800000u, 0xD65F03C0u };
        if (twrite_code(task, stub, stubcode, sizeof(stubcode)) != 0) {
            write_status("FAIL write_stub");
            free(imgs);
            mach_port_deallocate(mach_task_self(), task);
            return 7;
        }
        stub_anon = 1;
    }
    fprintf(stdout, "stub @ 0x%llx anon=%d\n", (unsigned long long)stub, stub_anon);

    raddr_t slide = 0;
    image_slide(task, tersafe, &slide);

    /* A: GOT (no suspend) */
    int got_hits = rewrite_gots(task, imgs, nimg, tersafe, addrs, naddr, stub);
    fprintf(stdout, "got_rewrites=%d\n", got_hits);

    /* B+C under short suspend */
    task_suspend(task);
    int data_hits = rewrite_tersafe_data_ptrs(task, tersafe, addrs, naddr, stub);
    fprintf(stdout, "data_rewrites=%d\n", data_hits);
    int leaf_ok = patch_leaf_rvas(task, tersafe, slide, anchor);
    fprintf(stdout, "leaf_ok=%d\n", leaf_ok);
    task_resume(task);

    free(imgs);
    mach_port_deallocate(mach_task_self(), task);

    char buf[220];
    if (data_hits > 0 || leaf_ok > 0) {
        snprintf(buf, sizeof(buf),
                 "OK mempatch got=%d data=%d leaf=%d syms=%d pid=%d time=%ld",
                 got_hits, data_hits, leaf_ok, naddr, (int)pid, (long)time(NULL));
        write_status(buf);
        fprintf(stdout, "%s\n", buf);
        return 0;
    }

    snprintf(buf, sizeof(buf),
             "FAIL mempatch got=%d data=0 leaf=0 syms=%d (need data/leaf; check tersafe ver)",
             got_hits, naddr);
    write_status(buf);
    fprintf(stdout, "%s\n", buf);
    return 8;
}
