#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <stdio.h>
#import <string.h>
#import <errno.h>
#import <sys/sysctl.h>
#import <sys/stat.h>
#import <time.h>
#import "TersafeThreadChaos.h"
#import "fishhook.h"

/*
 * ACE iOS 机型标记：
 *   iDevHwModel ← hw.machine
 *   iDevSysName ← UIDevice.systemName（真机 "iPhone OS"）
 *   iDevSysVer  ← UIDevice.systemVersion / kern.osproductversion
 *
 * 用户要求：最新机型 + 最新系统，减轻旧设备画像权重。
 * 当前画像（2026-08）：iPhone 17 Pro (iPhone18,1) + iOS 26.6 (23G71)
 */

#define SY_STATUS_PATH "/var/mobile/Library/Caches/sy_ports_status.txt"
/* Spoof tweak 默认打开安全 report hook（空缓冲，禁止 NULL） */
#ifndef SY_ENABLE_REPORT_HOOKS
#define SY_ENABLE_REPORT_HOOKS 1
#endif

static const char *kSpoofMachine = "iPhone18,1"; /* iPhone 17 Pro → iDevHwModel */
static const char *kSpoofBoard   = "V53AP";      /* board */
static const char *kSpoofOSVer   = "26.6";       /* iDevSysVer / osproductversion */
static const char *kSpoofOSBuild = "23G71";      /* kern.osversion */

static void sy_write_status(const char *line) {
    mkdir("/var/mobile/Library/Caches", 0755);
    const char *paths[] = { SY_STATUS_PATH, "/tmp/sy_ports_status.txt", NULL };
    for (int i = 0; paths[i]; i++) {
        FILE *f = fopen(paths[i], "w");
        if (!f) continue;
        fprintf(f, "%s\n", line);
        fclose(f);
        chmod(paths[i], 0644);
        break;
    }
    fprintf(stderr, "[水溶C] %s\n", line);
}

#pragma mark - sysctlbyname

static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);

static int sy_fill_str(void *oldp, size_t *oldlenp, const char *val) {
    size_t need = strlen(val) + 1;
    if (!oldp) {
        *oldlenp = need;
        return 0;
    }
    if (*oldlenp < need) {
        *oldlenp = need;
        errno = ENOMEM;
        return -1;
    }
    memcpy(oldp, val, need);
    *oldlenp = need;
    return 0;
}

static int sy_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                          void *newp, size_t newlen) {
    if (name && oldlenp) {
        if (!strcmp(name, "hw.machine"))
            return sy_fill_str(oldp, oldlenp, kSpoofMachine);
        if (!strcmp(name, "hw.model"))
            return sy_fill_str(oldp, oldlenp, kSpoofBoard);
        if (!strcmp(name, "kern.osproductversion"))
            return sy_fill_str(oldp, oldlenp, kSpoofOSVer);
        if (!strcmp(name, "kern.osversion"))
            return sy_fill_str(oldp, oldlenp, kSpoofOSBuild);
    }
    return orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
}

static void sy_hook_sysctl(void) {
    struct rebinding rb[] = {
        { "sysctlbyname", (void *)sy_sysctlbyname, (void **)&orig_sysctlbyname },
    };
    rebind_symbols(rb, 1);
}

#pragma mark - UIDevice

static NSString *(*orig_model)(id, SEL);
static NSString *(*orig_name)(id, SEL);
static NSString *(*orig_systemName)(id, SEL);
static NSString *(*orig_systemVersion)(id, SEL);
static NSString *(*orig_localizedModel)(id, SEL);

static NSString *sy_model(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"iPhone";
}
static NSString *sy_name(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"iPhone";
}
static NSString *sy_systemName(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"iPhone OS";
}
static NSString *sy_systemVersion(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"26.6";
}
static NSString *sy_localizedModel(id self, SEL _cmd) {
    (void)self; (void)_cmd;
    return @"iPhone";
}

static void sy_swizzle(Class cls, SEL sel, IMP neu, void **orig) {
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    *orig = (void *)method_getImplementation(m);
    method_setImplementation(m, neu);
}

static void sy_hook_uidevice(void) {
    Class cls = objc_getClass("UIDevice");
    if (!cls) return;
    sy_swizzle(cls, @selector(model), (IMP)sy_model, (void **)&orig_model);
    sy_swizzle(cls, @selector(name), (IMP)sy_name, (void **)&orig_name);
    sy_swizzle(cls, @selector(systemName), (IMP)sy_systemName, (void **)&orig_systemName);
    sy_swizzle(cls, @selector(systemVersion), (IMP)sy_systemVersion, (void **)&orig_systemVersion);
    sy_swizzle(cls, @selector(localizedModel), (IMP)sy_localizedModel, (void **)&orig_localizedModel);
}

#pragma mark - report fishhook（空缓冲，禁止返回 NULL）

#if SY_ENABLE_REPORT_HOOKS
static void *orig_unused[16];
/* 足够大的零页：当 AntiDataInfo* / char* 用，strlen=0 且字段多为 0 */
static uint8_t g_empty_report[256];

static void *hook_empty_ptr(void) {
    memset(g_empty_report, 0, sizeof(g_empty_report));
    return g_empty_report;
}

static int hook_recv_nop(void) { return 0; }
static int hook_enable_off(void) { return 0; }
static void hook_del_nop(void *p) { (void)p; }

static void sy_fishhook_report_only(void) {
    memset(g_empty_report, 0, sizeof(g_empty_report));
    struct rebinding rb[] = {
        /* GetReport → 非空空缓冲（绝不用 NULL） */
        { "TssSDKGetReportData",  (void *)hook_empty_ptr, &orig_unused[0] },
        { "TssSDKGetReportData2", (void *)hook_empty_ptr, &orig_unused[1] },
        { "TssSDKGetReportData3", (void *)hook_empty_ptr, &orig_unused[2] },
        { "TssSDKGetReportData4", (void *)hook_empty_ptr, &orig_unused[3] },
        { "tss_get_report_data",  (void *)hook_empty_ptr, &orig_unused[4] },
        { "tss_get_report_data2", (void *)hook_empty_ptr, &orig_unused[5] },
        { "tss_get_report_data3", (void *)hook_empty_ptr, &orig_unused[6] },
        { "tss_get_report_data4", (void *)hook_empty_ptr, &orig_unused[7] },
        /* 下发 / 签名 */
        { "TssSDKOnRecvData",      (void *)hook_recv_nop, &orig_unused[8] },
        { "TssSDKOnRecvSignature", (void *)hook_recv_nop, &orig_unused[9] },
        { "tss_sdk_rcv_anti_data", (void *)hook_recv_nop, &orig_unused[10] },
        /* 禁止开启取报 */
        { "tss_enable_get_report_data", (void *)hook_enable_off, &orig_unused[11] },
        /* Del：空操作（避免 double-free 空缓冲） */
        { "TssSDKDelReportData",  (void *)hook_del_nop, &orig_unused[12] },
        { "tss_del_report_data",  (void *)hook_del_nop, &orig_unused[13] },
    };
    rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
}
#endif

#pragma mark - toast

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
            lab.clipsToBounds = YES;
            CGFloat pad = 16;
            CGFloat maxW = MIN(bounds.size.width, bounds.size.height) - 48;
            CGSize sz = [lab sizeThatFits:CGSizeMake(maxW, 400)];
            lab.frame = CGRectMake((bounds.size.width - sz.width - pad * 2) / 2,
                                   bounds.size.height * 0.18,
                                   sz.width + pad * 2, sz.height + pad);
            [vc.view addSubview:lab];
            w.hidden = NO;
            sy_toast_window = w;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (sy_toast_window == w) {
                    w.hidden = YES;
                    sy_toast_window = nil;
                }
            });
        } @catch (__unused NSException *ex) {}
    });
}

#pragma mark - install

void sy_install_report_hooks(void) {
    static int once = 0;
    if (once) return;
    once = 1;

    sy_hook_sysctl();
    sy_hook_uidevice();
#if SY_ENABLE_REPORT_HOOKS
    sy_fishhook_report_only();
#endif
    char buf[260];
    snprintf(buf, sizeof(buf),
             "OK spoof=iphone18,1 report=empty os=%s build=%s board=%s time=%ld",
             kSpoofOSVer, kSpoofOSBuild, kSpoofBoard, (long)time(NULL));
    sy_write_status(buf);
    sy_show_toast(@"水溶C：机型画像 + 空 GetReport\niPhone 17 Pro + iOS 26.6");
}

void sy_thread_chaos_start(void) {}

__attribute__((constructor))
static void sy_entry(void) {
    sy_hook_sysctl();
    dispatch_async(dispatch_get_main_queue(), ^{
        sy_hook_uidevice();
    });
    sy_write_status("WAIT spoof-armed");

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        for (int i = 0; i < 8; i++) {
            sleep(1);
            dispatch_sync(dispatch_get_main_queue(), ^{ sy_hook_uidevice(); });
        }
        sy_install_report_hooks();
    });
}
