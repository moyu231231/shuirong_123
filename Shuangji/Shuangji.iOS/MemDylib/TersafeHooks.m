#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <sys/stat.h>
#import <unistd.h>
#import <string.h>
#import <stdio.h>
#import <time.h>
#import <dispatch/dispatch.h>
#import "TersafeThreadChaos.h"

/* 水溶C App 用 root 读此文件，代替游戏内弹窗 */
#define SY_STATUS_PATH "/var/mobile/Library/Caches/sy_ports_status.txt"

static void sy_write_status(const char *line) {
    mkdir("/var/mobile/Library/Caches", 0755);
    const char *paths[] = {
        SY_STATUS_PATH,
        "/tmp/sy_ports_status.txt",
        NULL
    };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "w");
        if (!f) continue;
        fprintf(f, "%s\n", line);
        fclose(f);
        chmod(paths[i], 0644);
        fprintf(stderr, "[水溶C] %s -> %s\n", line, paths[i]);
        return;
    }
    fprintf(stderr, "[水溶C] status write fail: %s\n", line);
}

/*
 * 弹窗/UIWindow 一出就闪 → 游戏内禁止任何 UI。
 * 只做：延迟后补丁 get_report* 导出；成功打日志。
 * 不用 fishhook / 内部 RVA / enable / UIKit。
 */

static const struct mach_header_64 *sy_hdr;

static size_t sy_page_size(void) { return (size_t)getpagesize(); }

static int sy_make_rwx(void *addr, size_t len) {
    size_t psz = sy_page_size();
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(psz - 1);
    size_t off = (uintptr_t)addr - page;
    size_t span = (off + len + psz - 1) & ~(psz - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, span,
                                  FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS)
        return mprotect((void *)page, span, PROT_READ | PROT_WRITE | PROT_EXEC) == 0 ? 0 : -1;
    return 0;
}

static void sy_make_rx(void *addr, size_t len) {
    size_t psz = sy_page_size();
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(psz - 1);
    size_t off = (uintptr_t)addr - page;
    size_t span = (off + len + psz - 1) & ~(psz - 1);
    vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
}

static void sy_flush_icache(void *addr, size_t len) {
#if defined(__aarch64__)
    __asm__ __volatile__("dsb ish" ::: "memory");
    uintptr_t p = (uintptr_t)addr & ~((uintptr_t)63);
    uintptr_t end = (uintptr_t)addr + len;
    for (; p < end; p += 64)
        __asm__ __volatile__("dc cvau, %0" :: "r"(p) : "memory");
    __asm__ __volatile__("dsb ish" ::: "memory");
    p = (uintptr_t)addr & ~((uintptr_t)63);
    for (; p < end; p += 64)
        __asm__ __volatile__("ic ivau, %0" :: "r"(p) : "memory");
    __asm__ __volatile__("dsb ish\n\tisb" ::: "memory");
#else
    (void)addr; (void)len;
#endif
}

static int sy_in_tersafe(void *fn) {
    if (!fn || !sy_hdr) return 0;
    uintptr_t a = (uintptr_t)fn;
    uintptr_t base = (uintptr_t)sy_hdr;
    return a >= base && a < base + 0x2000000;
}

static int sy_patch_ret0(void *fn) {
    if (!fn || !sy_in_tersafe(fn)) return -1;
    uint32_t code[2] = { 0xD2800000u, 0xD65F03C0u };
    if (sy_make_rwx(fn, sizeof(code)) != 0) return -2;
    memcpy(fn, code, sizeof(code));
    sy_flush_icache(fn, sizeof(code));
    sy_make_rx(fn, sizeof(code));
    return 0;
}

static int sy_find_tersafe(void) {
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (!strstr(name, "tersafe") && !strstr(name, "Tersafe")) continue;
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        sy_hdr = (const struct mach_header_64 *)h;
        return 0;
    }
    return -1;
}

static void *sy_dlsym_tersafe(const char *name) {
    if (sy_find_tersafe() != 0) return NULL;
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        const char *img = _dyld_get_image_name(i);
        if (!img || (!strstr(img, "tersafe") && !strstr(img, "Tersafe"))) continue;
        void *h = dlopen(img, RTLD_NOLOAD);
        if (!h) continue;
        void *p = dlsym(h, name);
        if (p) return p;
    }
    return NULL;
}

void sy_install_report_hooks(void) {
    static int once = 0;
    if (once) return;
    once = 1;

    if (sy_find_tersafe() != 0) {
        sy_write_status("FAIL no_tersafe");
        return;
    }

    int exp = 0;
    static const char *exports[] = {
        "tss_get_report_data", "tss_get_report_data2",
        "tss_get_report_data3", "tss_get_report_data4",
        "TssSDKGetReportData", "TssSDKGetReportData2",
        "TssSDKGetReportData3", "TssSDKGetReportData4",
        NULL
    };
    for (int i = 0; exports[i]; i++) {
        void *fn = sy_dlsym_tersafe(exports[i]);
        if (fn && sy_patch_ret0(fn) == 0) exp++;
    }
    char buf[160];
    if (exp > 0)
        snprintf(buf, sizeof(buf), "OK patched=%d time=%ld", exp, (long)time(NULL));
    else
        snprintf(buf, sizeof(buf), "FAIL patched=0 time=%ld", (long)time(NULL));
    sy_write_status(buf);
}

void sy_thread_chaos_start(void) {}

__attribute__((constructor))
static void sy_entry(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sy_write_status("WAIT loaded waiting_tersafe");
        for (int i = 0; i < 60; i++) {
            sleep(1);
            if (sy_find_tersafe() == 0) break;
        }
        if (sy_find_tersafe() != 0) {
            sy_write_status("FAIL tersafe_not_found");
            return;
        }
        sy_write_status("WAIT tersafe_found delay_20s");
        sleep(20);
        sy_install_report_hooks();
    });
}
