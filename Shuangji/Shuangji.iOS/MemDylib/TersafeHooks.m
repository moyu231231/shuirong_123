#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <libkern/OSCacheControl.h>
#import <sys/mman.h>
#import <unistd.h>
#import <string.h>
#import <sys/socket.h>
#import "TersafeThreadChaos.h"
#import "ShuiyongMem.h"
#import "fishhook.h"

/*
 * IDA:
 * - 举报/异常上报出站: get_report_data* → sub_37060 (GS) / CS 组 4013
 * - 延迟补丁 get_report* + fishhook send 吞 4013 兜底
 */

#pragma mark - aarch64 stub patch

static size_t sy_page_size(void) {
    return (size_t)getpagesize();
}

static int sy_make_rwx(void *addr, size_t len) {
    size_t psz = sy_page_size();
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(psz - 1);
    size_t off = (uintptr_t)addr - page;
    size_t span = (off + len + psz - 1) & ~(psz - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, span,
                                  FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        return mprotect((void *)page, span, PROT_READ | PROT_WRITE | PROT_EXEC) == 0 ? 0 : -1;
    }
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

#pragma mark - symbol resolve

static void *sy_dlsym_tersafe(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char *img = _dyld_get_image_name(i);
        if (!img) continue;
        if (!strstr(img, "tersafe") && !strstr(img, "Tersafe") && !strstr(img, "ACE")) continue;
        void *h = dlopen(img, RTLD_NOLOAD);
        if (!h) continue;
        p = dlsym(h, name);
        if (p) return p;
    }
    return NULL;
}

#pragma mark - fishhook：报告 API + send 吞 4013

static void *(*orig_TssSDKGetReportData)(void);
static void *(*orig_tss_get_report_data)(void);
static void *orig_unused[6];

static ssize_t (*orig_send)(int, const void *, size_t, int);
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t (*orig_write)(int, const void *, size_t);

static void *hook_TssSDKGetReportData(void) { return NULL; }
static void *hook_tss_get_report_data(void) { return NULL; }

static int sy_buf_is_report(const void *buf, size_t len) {
    if (!buf || len < 8) return 0;
    const uint8_t *p = (const uint8_t *)buf;
    if (sy_contains_4013(p, len)) return 1;
    if (sy_contains_nj_report_0e(p, len)) return 1;
    return 0;
}

static ssize_t hook_send(int fd, const void *buf, size_t len, int flags) {
    if (sy_buf_is_report(buf, len)) return (ssize_t)len; /* 假装发成功 */
    return orig_send ? orig_send(fd, buf, len, flags) : -1;
}

static ssize_t hook_sendto(int fd, const void *buf, size_t len, int flags,
                           const struct sockaddr *addr, socklen_t alen) {
    if (sy_buf_is_report(buf, len)) return (ssize_t)len;
    return orig_sendto ? orig_sendto(fd, buf, len, flags, addr, alen) : -1;
}

static ssize_t hook_write(int fd, const void *buf, size_t len) {
    /* 只拦明显报告包，避免误伤普通文件 write */
    if (len >= 8 && len <= 65536 && sy_contains_4013((const uint8_t *)buf, len))
        return (ssize_t)len;
    return orig_write ? orig_write(fd, buf, len) : -1;
}

static void sy_fishhook_all(void) {
    struct rebinding rb[] = {
        { "TssSDKGetReportData",  (void *)hook_TssSDKGetReportData,  (void **)&orig_TssSDKGetReportData },
        { "TssSDKGetReportData2", (void *)hook_TssSDKGetReportData,  &orig_unused[0] },
        { "TssSDKGetReportData3", (void *)hook_TssSDKGetReportData,  &orig_unused[1] },
        { "TssSDKGetReportData4", (void *)hook_TssSDKGetReportData,  &orig_unused[2] },
        { "tss_get_report_data",  (void *)hook_tss_get_report_data,  (void **)&orig_tss_get_report_data },
        { "tss_get_report_data2", (void *)hook_tss_get_report_data,  &orig_unused[3] },
        { "tss_get_report_data3", (void *)hook_tss_get_report_data,  &orig_unused[4] },
        { "tss_get_report_data4", (void *)hook_tss_get_report_data,  &orig_unused[5] },
        { "send",   (void *)hook_send,   (void **)&orig_send },
        { "sendto", (void *)hook_sendto, (void **)&orig_sendto },
        { "write",  (void *)hook_write,  (void **)&orig_write },
    };
    rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
}

#pragma mark - install

static int sy_count_patched = 0;

static void sy_show_hook_ok_alert(int patched) {
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSString *msg = [NSString stringWithFormat:
                             @"内存钩子已生效\n报告接口补丁 %d 个\nsend/4013 过滤已挂",
                             patched];
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
                    if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                        if (w.isKeyWindow) { win = w; break; }
                    }
                    if (!win && ((UIWindowScene *)scene).windows.count)
                        win = ((UIWindowScene *)scene).windows.firstObject;
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
            } else {
                /* 无 VC 时挂到临时 window */
                UIWindow *tw = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
                tw.windowLevel = UIWindowLevelAlert + 1;
                tw.rootViewController = [UIViewController new];
                [tw makeKeyAndVisible];
                [tw.rootViewController presentViewController:ac animated:YES completion:nil];
                objc_setAssociatedObject(ac, "sy_tw", tw, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
        } @catch (__unused NSException *ex) {
            NSLog(@"[水溶C] alert failed");
        }
    });
}

void sy_install_report_hooks(void) {
    static int once = 0;
    if (once) return;
    once = 1;

    int patched = 0;
    static const char *ret0_syms[] = {
        "tss_get_report_data",
        "tss_get_report_data2",
        "tss_get_report_data3",
        "tss_get_report_data4",
        "TssSDKGetReportData",
        "TssSDKGetReportData2",
        "TssSDKGetReportData3",
        "TssSDKGetReportData4",
        NULL
    };
    for (int i = 0; ret0_syms[i]; i++) {
        void *fn = sy_dlsym_tersafe(ret0_syms[i]);
        if (fn && sy_patch_ret0(fn) == 0) patched++;
    }

    void *en = sy_dlsym_tersafe("tss_enable_get_report_data");
    if (en && sy_patch_ret(en) == 0) patched++;

    sy_fishhook_all();
    sy_count_patched = patched;
    sy_show_hook_ok_alert(patched);
}

void sy_thread_chaos_start(void) {}

__attribute__((constructor))
static void sy_entry(void) {
    /*
     * 局内后注：tersafe 多半已加载，1s 起探测；
     * 冷启动仍给几秒缓冲，避免启动期改 TEXT。
     */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 12; i++) {
            sleep(i == 0 ? 1 : (i < 3 ? 2 : 3));
            void *probe = sy_dlsym_tersafe("tss_get_report_data");
            if (!probe) probe = sy_dlsym_tersafe("TssSDKGetReportData");
            if (probe) {
                sy_install_report_hooks();
                return;
            }
        }
        sy_fishhook_all();
    });
}
