#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <unistd.h>
#import <stdio.h>
#import <sys/stat.h>
#import <time.h>
#import "TersafeThreadChaos.h"
#import "fishhook.h"

/*
 * 不改 tersafe 机器码。fishhook 导入表：
 *   上报：get_report* / TssSDKGetReportData*
 *   检测下发：TssSDKOnRecvData / tss_sdk_rcv_anti_data
 */

#define SY_STATUS_PATH "/var/mobile/Library/Caches/sy_ports_status.txt"

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

#pragma mark - fishhook（不改 TEXT）

static void *orig_unused[10];
static void *hook_null(void) { return NULL; }
/* 收包类：当 int 返回 0 / void 忽略均可 */
static int hook_recv_nop(void) { return 0; }

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
        { "TssSDKOnRecvData",     (void *)hook_recv_nop, &orig_unused[8] },
        { "tss_sdk_rcv_anti_data", (void *)hook_recv_nop, &orig_unused[9] },
    };
    rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
}

#pragma mark - 悬浮窗

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
            NSLog(@"[水溶C] %@", msg);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (sy_toast_window == w) {
                    w.hidden = YES;
                    sy_toast_window = nil;
                }
            });
        } @catch (__unused NSException *ex) {}
    });
}

#pragma mark - locate

static int sy_tersafe_loaded(void) {
    uint32_t c = _dyld_image_count();
    for (uint32_t i = 0; i < c; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "tersafe") || strstr(name, "Tersafe")) return 1;
    }
    return 0;
}

#pragma mark - install

void sy_install_report_hooks(void) {
    static int once = 0;
    if (once) return;
    once = 1;

    /* 只 fishhook，绝不 vm_protect 改 tersafe 代码 */
    sy_fishhook_report_only();

    char buf[128];
    snprintf(buf, sizeof(buf), "OK fishhook=report+recv time=%ld", (long)time(NULL));
    sy_write_status(buf);

    sy_show_toast(@"水溶C：钩子已生效\n报告 + 检测收包\n(fishhook，未改机器码)");
}

void sy_thread_chaos_start(void) {}

__attribute__((constructor))
static void sy_entry(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sy_write_status("WAIT loaded");
        for (int i = 0; i < 40; i++) {
            sleep(1);
            if (sy_tersafe_loaded() ||
                dlsym(RTLD_DEFAULT, "tss_get_report_data") ||
                dlsym(RTLD_DEFAULT, "TssSDKGetReportData") ||
                dlsym(RTLD_DEFAULT, "TssSDKOnRecvData") ||
                dlsym(RTLD_DEFAULT, "tss_sdk_rcv_anti_data")) {
                sleep(3);
                sy_install_report_hooks();
                return;
            }
        }
        /* 无 tersafe 也挂导入表兜底 */
        sy_fishhook_report_only();
        sy_write_status("OK fishhook=fallback_no_tersafe");
        sy_show_toast(@"水溶C：未找到 tersafe\n已挂导入表兜底");
    });
}
