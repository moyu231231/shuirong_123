/*
 * 无 dylib 远程内存补丁：
 *   task_for_pid → 枚举 dyld → 解析 tersafe 导出 →
 *   1) 分配匿名桩 (MOV X0,#0; RET)
 *   2) 其它镜像 __DATA 里指向这些导出的指针改写到桩（等同 fishhook，不改 TEXT）
 *   3) 再写导出 prologue（挡住内部 BL；先 task_suspend 降竞态）
 * 不 dlopen、不落盘、不新增命名镜像。
 *
 *   sy_mempatch <pid>
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <mach-o/dyld_images.h>
#include <sys/stat.h>
#include <time.h>

#define STATUS_PATH "/var/mobile/Library/Caches/sy_ports_status.txt"
#define PAGE_MASK   ((mach_vm_address_t)0x3FFFu)

static void write_status(const char *line) {
    mkdir("/var/mobile/Library/Caches", 0755);
    FILE *f = fopen(STATUS_PATH, "w");
    if (!f) f = fopen("/tmp/sy_ports_status.txt", "w");
    if (!f) return;
    fprintf(f, "%s\n", line);
    fclose(f);
}

static kern_return_t tread(task_t task, mach_vm_address_t addr, void *buf, mach_vm_size_t sz) {
    mach_vm_size_t out = 0;
    return mach_vm_read_overwrite(task, addr, sz, (mach_vm_address_t)(uintptr_t)buf, &out);
}

static int twrite_raw(task_t task, mach_vm_address_t addr, const void *buf, mach_vm_size_t sz) {
    kern_return_t kr = mach_vm_write(task, addr, (vm_offset_t)(uintptr_t)buf, (mach_msg_type_number_t)sz);
    return kr == KERN_SUCCESS ? 0 : -1;
}

static int twrite_code(task_t task, mach_vm_address_t addr, const void *buf, mach_vm_size_t sz) {
    mach_vm_address_t page = addr & ~PAGE_MASK;
    mach_vm_size_t span = ((addr - page) + sz + PAGE_MASK) & ~PAGE_MASK;
    kern_return_t kr = mach_vm_protect(task, page, span, FALSE,
                                       VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        kr = mach_vm_protect(task, page, span, FALSE,
                             VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) return -1;
    if (twrite_raw(task, addr, buf, sz) != 0) return -2;
    mach_vm_protect(task, page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return 0;
}

typedef struct {
    mach_vm_address_t load;
    char path[512];
} remote_img_t;

static int load_images(task_t task, mach_vm_address_t all_info_addr,
                       remote_img_t **out_imgs, uint32_t *out_n) {
    struct dyld_all_image_infos infos;
    if (tread(task, all_info_addr, &infos, sizeof(infos)) != KERN_SUCCESS) return -1;
    if (!infos.infoArray || infos.infoArrayCount == 0 || infos.infoArrayCount > 4096) return -1;

    size_t arr_sz = sizeof(struct dyld_image_info) * infos.infoArrayCount;
    struct dyld_image_info *arr = (struct dyld_image_info *)malloc(arr_sz);
    if (!arr) return -1;
    if (tread(task, (mach_vm_address_t)(uintptr_t)infos.infoArray, arr, arr_sz) != KERN_SUCCESS) {
        free(arr);
        return -1;
    }

    remote_img_t *imgs = (remote_img_t *)calloc(infos.infoArrayCount, sizeof(remote_img_t));
    if (!imgs) { free(arr); return -1; }

    uint32_t n = 0;
    for (uint32_t i = 0; i < infos.infoArrayCount; i++) {
        if (!arr[i].imageLoadAddress) continue;
        imgs[n].load = (mach_vm_address_t)(uintptr_t)arr[i].imageLoadAddress;
        if (arr[i].imageFilePath) {
            tread(task, (mach_vm_address_t)(uintptr_t)arr[i].imageFilePath,
                  imgs[n].path, sizeof(imgs[n].path) - 1);
        }
        n++;
    }
    free(arr);
    *out_imgs = imgs;
    *out_n = n;
    return 0;
}

static mach_vm_address_t remote_sym(task_t task, mach_vm_address_t image, const char *want) {
    struct mach_header_64 mh;
    if (tread(task, image, &mh, sizeof(mh)) != KERN_SUCCESS) return 0;
    if (mh.magic != MH_MAGIC_64) return 0;

    mach_vm_address_t lc = image + sizeof(mh);
    struct segment_command_64 linkedit = {0};
    struct symtab_command symtab = {0};
    mach_vm_address_t slide = 0;
    int have_slide = 0;

    for (uint32_t i = 0; i < mh.ncmds; i++) {
        struct load_command cmd;
        if (tread(task, lc, &cmd, sizeof(cmd)) != KERN_SUCCESS) break;
        if (cmd.cmd == LC_SYMTAB) {
            tread(task, lc, &symtab, sizeof(symtab));
        } else if (cmd.cmd == LC_SEGMENT_64) {
            struct segment_command_64 seg;
            tread(task, lc, &seg, sizeof(seg));
            if (strncmp(seg.segname, "__TEXT", 16) == 0) {
                slide = image - seg.vmaddr;
                have_slide = 1;
            } else if (!have_slide && strncmp(seg.segname, "__PAGEZERO", 16) != 0) {
                slide = image - seg.vmaddr;
                have_slide = 1;
            }
            if (strncmp(seg.segname, "__LINKEDIT", 16) == 0) linkedit = seg;
        }
        lc += cmd.cmdsize;
    }
    if (!symtab.cmd || !linkedit.cmd) return 0;

    mach_vm_address_t base = linkedit.vmaddr + slide - linkedit.fileoff;
    char *strtbl = (char *)malloc(symtab.strsize);
    if (!strtbl) return 0;
    if (tread(task, base + symtab.stroff, strtbl, symtab.strsize) != KERN_SUCCESS) {
        free(strtbl);
        return 0;
    }

    char want2[256];
    snprintf(want2, sizeof(want2), "_%s", want);

    mach_vm_address_t hit = 0;
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

/* 扫描镜像可写段，把指向 targets 的指针改成 stub */
static int rewrite_gots(task_t task, remote_img_t *imgs, uint32_t nimg,
                        mach_vm_address_t tersafe_base,
                        const mach_vm_address_t *targets, int nt,
                        mach_vm_address_t stub) {
    int hits = 0;
    uint8_t *chunk = (uint8_t *)malloc(0x10000);
    if (!chunk) return 0;

    for (uint32_t ii = 0; ii < nimg; ii++) {
        mach_vm_address_t image = imgs[ii].load;
        if (!image || image == tersafe_base) continue; /* 不改 tersafe 内部指针 */

        struct mach_header_64 mh;
        if (tread(task, image, &mh, sizeof(mh)) != KERN_SUCCESS) continue;
        if (mh.magic != MH_MAGIC_64) continue;

        mach_vm_address_t lc = image + sizeof(mh);
        mach_vm_address_t slide = 0;
        int have_slide = 0;

        /* 先拿 slide */
        mach_vm_address_t lc0 = lc;
        for (uint32_t i = 0; i < mh.ncmds; i++) {
            struct load_command cmd;
            if (tread(task, lc0, &cmd, sizeof(cmd)) != KERN_SUCCESS) break;
            if (cmd.cmd == LC_SEGMENT_64) {
                struct segment_command_64 seg;
                tread(task, lc0, &seg, sizeof(seg));
                if (strncmp(seg.segname, "__TEXT", 16) == 0) {
                    slide = image - seg.vmaddr;
                    have_slide = 1;
                    break;
                }
            }
            lc0 += cmd.cmdsize;
        }
        if (!have_slide) continue;

        lc = image + sizeof(mh);
        for (uint32_t i = 0; i < mh.ncmds; i++) {
            struct load_command cmd;
            if (tread(task, lc, &cmd, sizeof(cmd)) != KERN_SUCCESS) break;
            if (cmd.cmd == LC_SEGMENT_64) {
                struct segment_command_64 seg;
                tread(task, lc, &seg, sizeof(seg));
                int writable = (seg.initprot & VM_PROT_WRITE) != 0;
                int is_data = strncmp(seg.segname, "__DATA", 6) == 0
                           || strncmp(seg.segname, "__AUTH_CONST", 12) == 0
                           || strncmp(seg.segname, "__DATA_CONST", 12) == 0;
                if (!writable && !is_data) { lc += cmd.cmdsize; continue; }
                if (seg.vmsize == 0 || seg.vmsize > 64 * 1024 * 1024) { lc += cmd.cmdsize; continue; }

                mach_vm_address_t seg_addr = seg.vmaddr + slide;
                mach_vm_size_t off = 0;
                while (off + 8 <= seg.vmsize) {
                    mach_vm_size_t nread = seg.vmsize - off;
                    if (nread > 0x10000) nread = 0x10000;
                    nread &= ~(mach_vm_size_t)7;
                    if (nread < 8) break;
                    if (tread(task, seg_addr + off, chunk, nread) != KERN_SUCCESS) {
                        off += nread;
                        continue;
                    }
                    for (mach_vm_size_t p = 0; p + 8 <= nread; p += 8) {
                        uint64_t v;
                        memcpy(&v, chunk + p, 8);
                        for (int t = 0; t < nt; t++) {
                            if (!targets[t] || v != (uint64_t)targets[t]) continue;
                            mach_vm_address_t at = seg_addr + off + p;
                            /* DATA_CONST 可能需先改保护 */
                            mach_vm_address_t page = at & ~PAGE_MASK;
                            mach_vm_protect(task, page, 0x4000, FALSE,
                                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
                            uint64_t nv = (uint64_t)stub;
                            if (twrite_raw(task, at, &nv, 8) == 0) hits++;
                        }
                    }
                    off += nread;
                }
            }
            lc += cmd.cmdsize;
        }
    }
    free(chunk);
    return hits;
}

static int patch_ret0(task_t task, mach_vm_address_t addr) {
    uint32_t code[2] = { 0xD2800000u, 0xD65F03C0u }; /* MOV X0,#0 ; RET */
    return twrite_code(task, addr, code, sizeof(code));
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
    mach_vm_address_t tersafe = 0;

    for (int t = 0; t < 40; t++) {
        free(imgs);
        imgs = NULL;
        nimg = 0;
        if (load_images(task, dyld.all_image_info_addr, &imgs, &nimg) != 0) {
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

    mach_vm_address_t addrs[16];
    int naddr = 0;
    memset(addrs, 0, sizeof(addrs));
    for (int i = 0; syms[i] && naddr < 16; i++) {
        mach_vm_address_t a = remote_sym(task, tersafe, syms[i]);
        if (!a) {
            fprintf(stdout, "miss %s\n", syms[i]);
            continue;
        }
        fprintf(stdout, "sym %s @ 0x%llx\n", syms[i], (unsigned long long)a);
        addrs[naddr++] = a;
    }
    if (naddr == 0) {
        write_status("FAIL no_syms");
        free(imgs);
        mach_port_deallocate(mach_task_self(), task);
        return 5;
    }

    /* 匿名可执行桩 */
    mach_vm_address_t stub = 0;
    kr = mach_vm_allocate(task, &stub, 0x4000, VM_FLAGS_ANYWHERE);
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
    fprintf(stdout, "stub @ 0x%llx\n", (unsigned long long)stub);

    task_suspend(task);

    int got_hits = rewrite_gots(task, imgs, nimg, tersafe, addrs, naddr, stub);
    fprintf(stdout, "got_rewrites=%d\n", got_hits);

    int text_ok = 0;
    for (int i = 0; i < naddr; i++) {
        if (patch_ret0(task, addrs[i]) == 0) {
            text_ok++;
            fprintf(stdout, "prologue ok 0x%llx\n", (unsigned long long)addrs[i]);
        } else {
            fprintf(stdout, "prologue fail 0x%llx\n", (unsigned long long)addrs[i]);
        }
    }

    task_resume(task);

    free(imgs);
    mach_port_deallocate(mach_task_self(), task);

    char buf[192];
    if (got_hits > 0 || text_ok > 0) {
        snprintf(buf, sizeof(buf),
                 "OK mempatch got=%d text=%d syms=%d pid=%d time=%ld",
                 got_hits, text_ok, naddr, (int)pid, (long)time(NULL));
        write_status(buf);
        fprintf(stdout, "%s\n", buf);
        return 0;
    }
    write_status("FAIL mempatch=0");
    return 8;
}
