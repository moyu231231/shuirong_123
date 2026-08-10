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
 * 稳定优先：只补丁 tersafe 公开导出 get_report*（已验证可拦上报）。
 * 内部 RVA（0x10E36C 等）RET0 易打偏/打中初始化 → 闪退且弹窗来不及出。
 * 成功提示用独立悬浮窗，不依赖 Unity 的 rootViewController。
 */

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

static void sy_make_rx(void *addr, size_t len) {
    size_t psz = sy_page_size();
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(psz - 1);
    size_t off = (uintptr_t)addr - page;
    size_t span = (off + len + psz - 1) & ~(psz - 1);
    vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
}

static int sy_patch_ret0(void *fn) {
    if (!fn) return -1;
    uint32_t code[2] = { 0xD2800000u, 0xD65F03C0u }; /* MOV X0,#0 ; RET */
    if (sy_make_rwx(fn, sizeof(code)) != 0) return -2;
    memcpy(fn, code, sizeof(code));
    sys_icache_invalidate(fn, sizeof(code));
    sy_make_rx(fn, sizeof(code));
    return 0;
}

static int sy_patch_ret(void *fn) {
    if (!fn) return -1;
    uint32_t code = 0xD65F03C0u;
    if (sy_make_rwx(fn, sizeof(code)) != 0) return -2;
    memcpy(fn, &code, sizeof(code));
    sys_icache_invalidate(fn, sizeof(code));
    sy_make_rx(fn, sizeof(code));
    return 0;
}

#pragma mark - locate

static int sy_tersafe_loaded(void) {
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "tersafe") || strstr(name, "Tersafe")) return 1;
    }
    return 0;
}

static void *sy_dlsym_tersafe(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
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

#pragma mark - fishhook

static void *orig_unused[8];
static void *hook_null(void) { return NULL; }

static void sy_fishhook_report_only(void) {
    struct rebinding rb[] = {
        { "TssSDKGetReportData",  (void *)hook_null, &orig_unused[0] },
        { "TssSDKGetReportData2", (void *)hook_null, &orig_unused[1] },
        { "TssSDKGetReportData3", (void *)hook_null, &orig_unused[2] },
        { "TssSDKGetReportData4", (void *)hook_null, &orig_unused[3] },
        { "tss_get_report_data",  (void *)hook_null, &orig_unused[4] },
        { "tss_get_report_data2", (void *)hook_null, &orig_unused[5] },
        { "tss_get_report_data3", (void *)hook_null, &orig_unused[6] },
        { "tss_get_report_data4", (void *)hook_null, &orig_unused[7] },
    };
    rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
}

#pragma mark - toast（独立窗，不碰游戏 VC）

static UIWindow *sy_toast_window;

static void sy_show_toast(NSString *msg) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            if (sy_toast_window) {
                sy_toast_window.hidden = YES;
                sy_toast_window = nil;
            }
            CGRect bounds = UIScreen.mainScreen.bounds;
            UIWindow *w = [[UIWindow alloc] initWithFrame:bounds];
            w.windowLevel = UIWindowLevelStatusBar + 100;
            w.backgroundColor = UIColor.clearColor;
            w.userInteractionEnabled = NO;
            if (@available(iOS 13.0, *)) {
                for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                    if ([scene isKindOfClass:[UIWindowScene class]] &&
                        scene.activationState == UISceneActivationStateForegroundActive) {
                        w.windowScene = (UIWindowScene *)scene;
                        break;
                    }
                }
            }
            UIViewController *vc = [UIViewController new];
            vc.view.backgroundColor = UIColor.clearColor;
            w.rootViewController = vc;

            UILabel *lab = [[UILabel alloc] init];
            lab.text = msg;
            lab.numberOfLines = 0;
            lab.textAlignment = NSTextAlignmentCenter;
            lab.font = [UIFont boldSystemFontOfSize:15];
            lab.textColor = UIColor.whiteColor;
            lab.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
            lab.layer.cornerRadius = 12;
            lab.layer.masksToBounds = YES;
            CGFloat pad = 16;
            CGFloat maxW = MIN(bounds.size.width, bounds.size.height) - 48;
            CGSize sz = [lab sizeThatFits:CGSizeMake(maxW, 400)];
            lab.frame = CGRectMake((bounds.size.width - sz.width - pad * 2) / 2,
                                   bounds.size.height * 0.18,
                                   sz.width + pad * 2,
                                   sz.height + pad);
            [vc.view addSubview:lab];
            w.hidden = NO;
            sy_toast_window = w;

            NSLog(@"[水溶C] %@", msg);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (sy_toast_window == w) {
                    w.hidden = YES;
                    sy_toast_window = nil;
                }
            });
        } @catch (__unused NSException *ex) {
            NSLog(@"[水溶C] toast failed");
        }
    });
}

#pragma mark - install

void sy_install_report_hooks(void) {
    static int once = 0;
    if (once) return;
    once = 1;

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
    void *en = sy_dlsym_tersafe("tss_enable_get_report_data");
    if (en && sy_patch_ret(en) == 0) exp++;

    sy_fishhook_report_only();

    NSString *msg = [NSString stringWithFormat:
                     @"水溶C：报告钩子已生效（导出 %d）\n未打内部 RVA（防闪退）",
                     exp];
    /* 等 Unity 建好窗口再出浮条；失败则稍后再试一次 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        sy_show_toast(msg);
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!sy_toast_window) sy_show_toast(msg);
    });
}

void sy_thread_chaos_start(void) {}

__attribute__((constructor))
static void sy_entry(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 30; i++) {
            sleep(1);
            if (sy_tersafe_loaded() ||
                sy_dlsym_tersafe("tss_get_report_data") ||
                sy_dlsym_tersafe("TssSDKGetReportData")) {
                sy_install_report_hooks();
                return;
            }
        }
        sy_fishhook_report_only();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            sy_show_toast(@"水溶C：未找到 tersafe，仅挂导入表");
        });
    });
}
