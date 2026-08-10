#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <libkern/OSCacheControl.h>
#import <sys/mman.h>
#import <unistd.h>
#import <string.h>
#import "TersafeThreadChaos.h"
#import "fishhook.h"

/*
 * 依据 tersafe v7.7.49.57576 IDA 全景（用户报告）定点补丁：
 *
 * 【举报/异常上报】
 *   导出 get_report* / TssSDKGetReportData*
 *   0x3F284 COREREPORT 分发、0x3E720 TDM REPORT、0x3F48C 路由、0x100A20 shell_report
 *
 * 【检测总闸 / 扫内存（防认出我们的注入）】
 *   0x10E36C 总闸（CRC/send/inline_hook）
 *   0x20167C / 0x21196C 内存区域扫描
 *   0x6F3C shadowed、0xE59AC bin_patch、0x89E40 模块 MD5
 *
 * 禁止：挂起线程、钩 send/write/ioctl、乱扫 ACE 线程名。
 * 地址为 IDA imagebase=0 时的文件 VA，运行时 + slide。
 */

typedef struct {
    uint32_t rva;
    const char *tag;
} sy_rva_t;

#pragma mark - page / patch

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

static int sy_make_rx(void *addr, size_t len) {
    size_t psz = sy_page_size();
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(psz - 1);
    size_t off = (uintptr_t)addr - page;
    size_t span = (off + len + psz - 1) & ~(psz - 1);
    vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return 0;
}

static void sy_flush_icache(void *addr, size_t len) {
    sys_icache_invalidate(addr, len);
}

/// MOV X0,#0 ; RET  —— 比单 RET 更安全（调用方读返回值）
static int sy_patch_ret0(void *fn) {
    if (!fn) return -1;
    uint32_t code[2] = { 0xD2800000u, 0xD65F03C0u };
    if (sy_make_rwx(fn, sizeof(code)) != 0) return -2;
    memcpy(fn, code, sizeof(code));
    sy_flush_icache(fn, sizeof(code));
    sy_make_rx(fn, sizeof(code));
    return 0;
}

static int sy_patch_ret(void *fn) {
    if (!fn) return -1;
    uint32_t code = 0xD65F03C0u;
    if (sy_make_rwx(fn, sizeof(code)) != 0) return -2;
    memcpy(fn, &code, sizeof(code));
    sy_flush_icache(fn, sizeof(code));
    sy_make_rx(fn, sizeof(code));
    return 0;
}

#pragma mark - locate tersafe

static const struct mach_header_64 *sy_tersafe_hdr;
static intptr_t sy_tersafe_slide;

static int sy_find_tersafe(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (!strstr(name, "tersafe") && !strstr(name, "Tersafe")) continue;
        const struct mach_header *h = _dyld_get_image_header(i);
        if (!h || h->magic != MH_MAGIC_64) continue;
        sy_tersafe_hdr = (const struct mach_header_64 *)h;
        sy_tersafe_slide = _dyld_get_image_vmaddr_slide(i);
        return 0;
    }
    return -1;
}

static void *sy_rva(uint32_t rva) {
    if (!sy_tersafe_hdr) return NULL;
    return (void *)((uintptr_t)rva + (uintptr_t)sy_tersafe_slide);
}

static void *sy_dlsym_tersafe(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    if (sy_find_tersafe() != 0) return NULL;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *img = _dyld_get_image_name(i);
        if (!img || (!strstr(img, "tersafe") && !strstr(img, "Tersafe"))) continue;
        void *h = dlopen(img, RTLD_NOLOAD);
        if (!h) continue;
        p = dlsym(h, name);
        if (p) return p;
    }
    return NULL;
}

#pragma mark - fishhook：仅报告导入

static void *(*orig_TssSDKGetReportData)(void);
static void *(*orig_tss_get_report_data)(void);
static void *orig_unused[6];
static void *hook_null(void) { return NULL; }

static void sy_fishhook_report_only(void) {
    struct rebinding rb[] = {
        { "TssSDKGetReportData",  (void *)hook_null, (void **)&orig_TssSDKGetReportData },
        { "TssSDKGetReportData2", (void *)hook_null, &orig_unused[0] },
        { "TssSDKGetReportData3", (void *)hook_null, &orig_unused[1] },
        { "TssSDKGetReportData4", (void *)hook_null, &orig_unused[2] },
        { "tss_get_report_data",  (void *)hook_null, (void **)&orig_tss_get_report_data },
        { "tss_get_report_data2", (void *)hook_null, &orig_unused[3] },
        { "tss_get_report_data3", (void *)hook_null, &orig_unused[4] },
        { "tss_get_report_data4", (void *)hook_null, &orig_unused[5] },
    };
    rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
}

#pragma mark - IDA RVA 表

/* 先瘫扫内存/补丁计数，再瘫总闸与上报，降低「改 TEXT 被扫到」窗口 */
static const sy_rva_t kHideInject[] = {
    { 0x000E59AC, "bin_patch" },
    { 0x0020167C, "vm_region_scan" },
    { 0x0021196C, "vm_scan_dladdr" },
    { 0x00006F3C, "shadowed" },
    { 0x00089E40, "mod_md5" },
};

static const sy_rva_t kMasterGate[] = {
    { 0x0010E36C, "ms_ctrl_10E36C" }, /* CRC/inline_hook/send 总闸 */
};

static const sy_rva_t kReportCore[] = {
    { 0x0003F284, "COREREPORT" },
    { 0x0003E720, "TDM_REPORT" },
    { 0x0003F48C, "COREREPORT_route" },
    { 0x00100A20, "shell_report" },
};

static int sy_patch_rva_table(const sy_rva_t *tab, size_t n) {
    int ok = 0;
    for (size_t i = 0; i < n; i++) {
        void *fn = sy_rva(tab[i].rva);
        if (!fn) continue;
        /* 粗验：非全零页才补 */
        uint32_t w = 0;
        memcpy(&w, fn, 4);
        if (w == 0) continue;
        if (sy_patch_ret0(fn) == 0) ok++;
    }
    return ok;
}

#pragma mark - alert

static void sy_present_alert(NSString *msg, int triesLeft) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            UIAlertController *ac =
                [UIAlertController alertControllerWithTitle:@"水溶C"
                                                    message:msg
                                             preferredStyle:UIAlertControllerStyleAlert];
            [ac addAction:[UIAlertAction actionWithTitle:@"好"
                                                   style:UIAlertActionStyleDefault
                                                 handler:nil]];
            UIWindow *win = nil;
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                        if (w.isKeyWindow) { win = w; break; }
                    }
                    if (!win) win = ((UIWindowScene *)scene).windows.firstObject;
                    if (win) break;
                }
            }
            if (!win) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
                win = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
            }
            if (!win) win = UIApplication.sharedApplication.windows.firstObject;
            UIViewController *root = win.rootViewController;
            while (root.presentedViewController) root = root.presentedViewController;
            if (root) {
                [root presentViewController:ac animated:YES completion:nil];
                return;
            }
            if (triesLeft > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    sy_present_alert(msg, triesLeft - 1);
                });
                return;
            }
            UIWindow *tw = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
            tw.windowLevel = UIWindowLevelAlert + 1;
            tw.rootViewController = [UIViewController new];
            [tw makeKeyAndVisible];
            [tw.rootViewController presentViewController:ac animated:YES completion:nil];
            objc_setAssociatedObject(ac, "sy_tw", tw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        } @catch (__unused NSException *ex) {
            if (triesLeft > 0) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    sy_present_alert(msg, triesLeft - 1);
                });
            }
        }
    });
}

#pragma mark - install

void sy_install_report_hooks(void) {
    static int once = 0;
    if (once) return;
    once = 1;

    int exp = 0, hide = 0, gate = 0, rep = 0;

    /* 1) 公开导出：取报告变空 */
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
    void *en = sy_dlsym_tersafe("tss_enable_get_report_data");
    if (en && sy_patch_ret(en) == 0) exp++;

    sy_fishhook_report_only();

    /* 2) 内部 RVA（需 slide） */
    if (sy_find_tersafe() == 0) {
        hide = sy_patch_rva_table(kHideInject, sizeof(kHideInject) / sizeof(kHideInject[0]));
        gate = sy_patch_rva_table(kMasterGate, sizeof(kMasterGate) / sizeof(kMasterGate[0]));
        rep  = sy_patch_rva_table(kReportCore, sizeof(kReportCore) / sizeof(kReportCore[0]));
    }

    NSString *msg = [NSString stringWithFormat:
                     @"报告/检测补丁已生效\n"
                     @"导出报告 %d · 扫内存/补丁检测 %d\n"
                     @"总闸10E36C %d · COREREPORT等 %d\n"
                     @"未动游戏线程 / 未钩 send",
                     exp, hide, gate, rep];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sy_present_alert(msg, 6);
    });
}

void sy_thread_chaos_start(void) {
    /* 永久空：禁止挂起任何线程 */
}

__attribute__((constructor))
static void sy_entry(void) {
    /*
     * 冷启动才加载 dylib。游戏运行中注入只改磁盘，当前进程无效果。
     * 等 tersafe 映射后再打补丁。
     */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 20; i++) {
            sleep(2);
            if (sy_find_tersafe() == 0 ||
                sy_dlsym_tersafe("tss_get_report_data") ||
                sy_dlsym_tersafe("TssSDKGetReportData")) {
                sy_install_report_hooks();
                return;
            }
        }
        /* 仍无 tersafe：只挂导出 fishhook */
        sy_fishhook_report_only();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sy_present_alert(@"未找到 tersafe，仅挂了导入表兜底", 4);
        });
    });
}
