#import "TersafeThreadChaos.h"
#import "ShuiyongMem.h"
#import "fishhook.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <pthread.h>
#import <sys/socket.h>
#import <string.h>
#import <stdlib.h>
#import <stdatomic.h>

/*
 * 上报通道封堵（进程内）：
 * 1) get_report_data / del / encrypt 入口抽空
 * 2) send/sendto/write 载荷特征吞掉
 * 3) 对疑似 ACE/CS/report 工作线程：降优先 + 间歇挂起，打乱上报时序
 * 4) pthread_create 拦截：新开的上报类线程直接高延迟/可挂起
 *
 * 不打印业务提示字符串到 UI；仅 os_log 便于真机调试。
 */

#pragma mark - report API

typedef int (*fn_get_report)(void *buf, int *len);
typedef int (*fn_del_report)(void);
typedef int (*fn_enc)(void *in, int in_len, void *out, int *out_len);

static fn_get_report orig_get_report;
static fn_get_report orig_get_report_v2;
static fn_get_report orig_sdk_get_report;
static fn_del_report orig_del_report;
static fn_del_report orig_sdk_del_report;
static fn_enc orig_encrypt;

static atomic_int g_drop_reports = 1;
static atomic_int g_chaos = 1;

static int hooked_get_report(void *buf, int *len) {
    if (atomic_load(&g_drop_reports)) {
        if (len) *len = 0;
        if (buf && len && *len > 0) memset(buf, 0, (size_t)*len);
        return 0;
    }
    return orig_get_report ? orig_get_report(buf, len) : 0;
}

static int hooked_get_report_v2(void *buf, int *len) {
    if (atomic_load(&g_drop_reports)) {
        if (len) *len = 0;
        return 0;
    }
    return orig_get_report_v2 ? orig_get_report_v2(buf, len) : 0;
}

static int hooked_sdk_get_report(void *buf, int *len) {
    if (atomic_load(&g_drop_reports)) {
        if (len) *len = 0;
        return 0;
    }
    return orig_sdk_get_report ? orig_sdk_get_report(buf, len) : 0;
}

static int hooked_del_report(void) {
    return orig_del_report ? orig_del_report() : 0;
}

static int hooked_sdk_del_report(void) {
    return orig_sdk_del_report ? orig_sdk_del_report() : 0;
}

static int hooked_encrypt(void *in, int in_len, void *out, int *out_len) {
    /* 上报加密出口：清空输出，使 CS/GS 发出去也是废包 */
    if (atomic_load(&g_drop_reports)) {
        if (out_len) {
            int n = *out_len;
            if (out && n > 0) memset(out, 0, (size_t)n);
            *out_len = 0;
        }
        return 0;
    }
    return orig_encrypt ? orig_encrypt(in, in_len, out, out_len) : -1;
}

#pragma mark - socket

typedef ssize_t (*fn_send)(int, const void *, size_t, int);
typedef ssize_t (*fn_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
typedef ssize_t (*fn_write)(int, const void *, size_t);

static fn_send orig_send;
static fn_sendto orig_sendto;
static fn_write orig_write;

static int should_drop_payload(const void *buf, size_t len) {
    if (!buf || len < 8) return 0;
    const uint8_t *p = (const uint8_t *)buf;
    if (sy_contains_4013(p, len)) return 1;
    if (sy_contains_nj_report_0e(p, len)) return 1;
    return 0;
}

static ssize_t hooked_send(int fd, const void *buf, size_t len, int flags) {
    if (should_drop_payload(buf, len)) return (ssize_t)len;
    return orig_send ? orig_send(fd, buf, len, flags) : -1;
}

static ssize_t hooked_sendto(int fd, const void *buf, size_t len, int flags,
                             const struct sockaddr *addr, socklen_t alen) {
    if (should_drop_payload(buf, len)) return (ssize_t)len;
    return orig_sendto ? orig_sendto(fd, buf, len, flags, addr, alen) : -1;
}

static ssize_t hooked_write(int fd, const void *buf, size_t len) {
    if (should_drop_payload(buf, len)) return (ssize_t)len;
    return orig_write ? orig_write(fd, buf, len) : -1;
}

#pragma mark - pthread_create / thread name

typedef int (*fn_pthread_create)(pthread_t *, const pthread_attr_t *, void *(*)(void *), void *);
typedef int (*fn_pthread_setname)(pthread_t, const char *);
static fn_pthread_create orig_pthread_create;
static fn_pthread_setname orig_pthread_setname_np;

static int name_looks_report(const char *name) {
    if (!name) return 0;
    /* tersafe / ACE 常见线程名片段（大小写不敏感手工比） */
    char buf[64];
    size_t n = strlen(name);
    if (n >= sizeof(buf)) n = sizeof(buf) - 1;
    for (size_t i = 0; i < n; i++) {
        char c = name[i];
        if (c >= 'A' && c <= 'Z') c = (char)(c - 'A' + 'a');
        buf[i] = c;
    }
    buf[n] = 0;
    if (strstr(buf, "ace")) return 1;
    if (strstr(buf, "tss")) return 1;
    if (strstr(buf, "report")) return 1;
    if (strstr(buf, "cs2") || strstr(buf, "cs3")) return 1;
    if (strstr(buf, "anticheat")) return 1;
    if (strstr(buf, "tersafe")) return 1;
    if (strstr(buf, "rp_queue") || strstr(buf, "rpq")) return 1;
    if (strstr(buf, "send_cs") || strstr(buf, "send_gs")) return 1;
    return 0;
}

struct sy_thread_wrap {
    void *(*start)(void *);
    void *arg;
    int mark_report;
};

static void *sy_thread_entry(void *arg) {
    struct sy_thread_wrap *w = (struct sy_thread_wrap *)arg;
    void *(*start)(void *) = w->start;
    void *a = w->arg;
    int mark = w->mark_report;
    free(w);

    if (mark && atomic_load(&g_chaos)) {
        /* 上报线程：压到后台 + 随机拖延，打乱心跳/上报节拍 */
        pthread_set_qos_class_self_np(QOS_CLASS_BACKGROUND, 0);
        usleep(800000 + (arc4random_uniform(1200) * 1000));
    }
    return start ? start(a) : NULL;
}

static int hooked_pthread_create(pthread_t *t, const pthread_attr_t *attr,
                                 void *(*start)(void *), void *arg) {
    if (!orig_pthread_create) return -1;
    /* 无法在 create 时拿到名字；先包一层，setname 时再标记挂起列表 */
    struct sy_thread_wrap *w = (struct sy_thread_wrap *)calloc(1, sizeof(*w));
    if (!w) return orig_pthread_create(t, attr, start, arg);
    w->start = start;
    w->arg = arg;
    w->mark_report = 0;
    return orig_pthread_create(t, attr, sy_thread_entry, w);
}

static int hooked_pthread_setname_np(pthread_t t, const char *name) {
    int r = orig_pthread_setname_np ? orig_pthread_setname_np(t, name) : 0;
    if (name_looks_report(name) && atomic_load(&g_chaos)) {
        /* 记下 mach thread，供混沌循环挂起 */
        mach_port_t mt = pthread_mach_thread_np(t);
        if (mt != MACH_PORT_NULL) {
            thread_suspend(mt);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                           dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                thread_resume(mt);
            });
        }
    }
    return r;
}

#pragma mark - chaos loop：扫线程名，对上报线程脉冲挂起

static int thread_name_of(thread_t th, char *out, size_t outlen) {
    pthread_t pt = pthread_from_mach_thread_np(th);
    if (!pt) return -1;
    return pthread_getname_np(pt, out, outlen);
}

static void chaos_pulse_once(void) {
    if (!atomic_load(&g_chaos)) return;

    thread_act_array_t threads = NULL;
    mach_msg_type_number_t count = 0;
    if (task_threads(mach_task_self(), &threads, &count) != KERN_SUCCESS) return;

    for (mach_msg_type_number_t i = 0; i < count; i++) {
        char name[64] = {0};
        if (thread_name_of(threads[i], name, sizeof(name)) != 0) continue;
        if (!name_looks_report(name)) continue;

        /* 脉冲：挂起数十毫秒，破坏上报状态机，不长期冻死以免拖崩主逻辑 */
        thread_suspend(threads[i]);
        usleep(30000 + arc4random_uniform(70000));
        thread_resume(threads[i]);

        thread_extended_policy_data_t pol;
        pol.timeshare = 0;
        thread_policy_set(threads[i], THREAD_EXTENDED_POLICY,
                          (thread_policy_t)&pol, THREAD_EXTENDED_POLICY_COUNT);
    }

    for (mach_msg_type_number_t i = 0; i < count; i++)
        mach_port_deallocate(mach_task_self(), threads[i]);
    vm_deallocate(mach_task_self(), (vm_address_t)threads, sizeof(thread_t) * count);
}

void sy_thread_chaos_start(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            while (atomic_load(&g_chaos)) {
                chaos_pulse_once();
                /* 1.2s~2.8s 抖动，避免被节律检测摸到固定周期 */
                useconds_t wait = 1200000 + arc4random_uniform(1600000);
                usleep(wait);
            }
        });
    });
}

#pragma mark - install hooks

static void rebind1(const char *name, void *rep, void **orig) {
    if (!dlsym(RTLD_DEFAULT, name) && name[0] != '_') {
        /* try with underscore */
    }
    struct rebinding rb = { name, rep, orig };
    rebind_symbols((struct rebinding[1]){rb}, 1);
}

void sy_install_report_hooks(void) {
    static const char *get_names[] = {
        "tss_get_report_data", "_tss_get_report_data",
        "tss_get_report_data2", "_tss_get_report_data2",
        "tss_get_report_data3", "_tss_get_report_data3",
        "TssSDKGetReportData", "_TssSDKGetReportData",
        "TssSDKGetReportData2", "_TssSDKGetReportData2",
        NULL
    };
    for (int i = 0; get_names[i]; i++) {
        if (strstr(get_names[i], "SDK"))
            rebind1(get_names[i], (void *)hooked_sdk_get_report, (void **)&orig_sdk_get_report);
        else if (strstr(get_names[i], "2") || strstr(get_names[i], "3"))
            rebind1(get_names[i], (void *)hooked_get_report_v2, (void **)&orig_get_report_v2);
        else
            rebind1(get_names[i], (void *)hooked_get_report, (void **)&orig_get_report);
    }

    rebind1("tss_del_report_data", (void *)hooked_del_report, (void **)&orig_del_report);
    rebind1("_tss_del_report_data", (void *)hooked_del_report, (void **)&orig_del_report);
    rebind1("TssSDKDelReportData", (void *)hooked_sdk_del_report, (void **)&orig_sdk_del_report);

    rebind1("tss_sdk_encryptpacket", (void *)hooked_encrypt, (void **)&orig_encrypt);
    rebind1("_tss_sdk_encryptpacket", (void *)hooked_encrypt, (void **)&orig_encrypt);

    rebind_symbols((struct rebinding[5]){
        { "send", (void *)hooked_send, (void **)&orig_send },
        { "sendto", (void *)hooked_sendto, (void **)&orig_sendto },
        { "write", (void *)hooked_write, (void **)&orig_write },
        { "pthread_create", (void *)hooked_pthread_create, (void **)&orig_pthread_create },
        { "pthread_setname_np", (void *)hooked_pthread_setname_np, (void **)&orig_pthread_setname_np },
    }, 5);
}
