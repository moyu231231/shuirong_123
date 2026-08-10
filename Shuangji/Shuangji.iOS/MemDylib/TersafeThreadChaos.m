#import "TersafeThreadChaos.h"
#import "ShuiyongMem.h"
#import "fishhook.h"

#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <string.h>
#import <stdatomic.h>

/*
 * 对照 Desktop/解密/tersafe.framework/tersafe 导出表 + ARM64 反汇编：
 *
 * 伪代码 switch 分发入口（不要整表砍，会断 CS 心跳）：
 *   TssSDKIoctl  → 直接 B 到 tp2_sdk_ioctl (0x2bea8)
 *   tp2_sdk_ioctl：大量 BR Xn，典型 ioctl request switch/跳转表
 *   tss_sdk_ioctl (0x28fb4)：短封装，很快 RET
 *
 * 真正跟「检测任务落地」相关、可导出挂钩的叶子：
 *   tss_sdk_rcv_anti_data     — 收 anti/检测数据（扫描任务入口）
 *   tss_enable_get_report_data— 打开取报告开关
 *   tss_get_report_data* / TssSDKGetReportData* — 游戏拉报告外发
 *   tss_sdk_ischeatpacket     — 本包已是 MOV W0,#0; RET，无需再钩
 *
 * 4013 仍由端口层管；本 dylib 不 hook send 拦 4013。
 * 不挂起线程、不 hook 整份 ioctl。
 */

#pragma mark - get_report / del_report

typedef int (*fn_get_report)(void *buf, int *len);
typedef int (*fn_del_report)(void);
typedef int (*fn_enable_report)(int enable);
typedef int (*fn_rcv_anti)(const void *data, int len);

static fn_get_report orig_get_report;
static fn_get_report orig_get_report_v2;
static fn_get_report orig_sdk_get_report;
static fn_del_report orig_del_report;
static fn_del_report orig_sdk_del_report;
static fn_enable_report orig_enable_report;
static fn_rcv_anti orig_rcv_anti;

static atomic_int g_drop_reports = 1;
static atomic_int g_drop_anti = 1;

static int hooked_get_report(void *buf, int *len) {
    if (atomic_load(&g_drop_reports)) {
        if (len) *len = 0;
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

/* 禁止打开「取报告」开关 */
static int hooked_enable_report(int enable) {
    (void)enable;
    if (atomic_load(&g_drop_reports)) return 0;
    return orig_enable_report ? orig_enable_report(enable) : 0;
}

/* 检测任务下发入口：丢掉 anti data，不进 MRPCS CScanThread 流水线 */
static int hooked_rcv_anti(const void *data, int len) {
    (void)data;
    (void)len;
    if (atomic_load(&g_drop_anti)) return 0;
    return orig_rcv_anti ? orig_rcv_anti(data, len) : 0;
}

#pragma mark - install

void sy_thread_chaos_start(void) {
    /* 不用线程挂起 */
}

static void rebind1(const char *name, void *rep, void **orig) {
    struct rebinding rb = { name, rep, orig };
    rebind_symbols((struct rebinding[1]){rb}, 1);
}

void sy_install_report_hooks(void) {
    /* 1) 检测数据入口 */
    rebind1("tss_sdk_rcv_anti_data", (void *)hooked_rcv_anti, (void **)&orig_rcv_anti);
    rebind1("_tss_sdk_rcv_anti_data", (void *)hooked_rcv_anti, (void **)&orig_rcv_anti);

    /* 2) 取报告开关 */
    rebind1("tss_enable_get_report_data", (void *)hooked_enable_report, (void **)&orig_enable_report);
    rebind1("_tss_enable_get_report_data", (void *)hooked_enable_report, (void **)&orig_enable_report);

    /* 3) 报告出口（含 2/3/4 / SDK 变体，均来自本包导出表） */
    static const char *get_names[] = {
        "tss_get_report_data", "_tss_get_report_data",
        "tss_get_report_data2", "_tss_get_report_data2",
        "tss_get_report_data3", "_tss_get_report_data3",
        "tss_get_report_data4", "_tss_get_report_data4",
        "TssSDKGetReportData", "_TssSDKGetReportData",
        "TssSDKGetReportData2", "_TssSDKGetReportData2",
        "TssSDKGetReportData3", "_TssSDKGetReportData3",
        "TssSDKGetReportData4", "_TssSDKGetReportData4",
        NULL
    };
    for (int i = 0; get_names[i]; i++) {
        if (strstr(get_names[i], "SDK"))
            rebind1(get_names[i], (void *)hooked_sdk_get_report, (void **)&orig_sdk_get_report);
        else if (strstr(get_names[i], "2") || strstr(get_names[i], "3") || strstr(get_names[i], "4"))
            rebind1(get_names[i], (void *)hooked_get_report_v2, (void **)&orig_get_report_v2);
        else
            rebind1(get_names[i], (void *)hooked_get_report, (void **)&orig_get_report);
    }

    rebind1("tss_del_report_data", (void *)hooked_del_report, (void **)&orig_del_report);
    rebind1("_tss_del_report_data", (void *)hooked_del_report, (void **)&orig_del_report);
    rebind1("tss_del_report_data3", (void *)hooked_del_report, (void **)&orig_del_report);
    rebind1("_tss_del_report_data3", (void *)hooked_del_report, (void **)&orig_del_report);
    rebind1("tss_del_report_data4", (void *)hooked_del_report, (void **)&orig_del_report);
    rebind1("_tss_del_report_data4", (void *)hooked_del_report, (void **)&orig_del_report);
    rebind1("TssSDKDelReportData", (void *)hooked_sdk_del_report, (void **)&orig_sdk_del_report);
    rebind1("TssSDKDelReportData3", (void *)hooked_sdk_del_report, (void **)&orig_sdk_del_report);
    rebind1("TssSDKDelReportData4", (void *)hooked_sdk_del_report, (void **)&orig_sdk_del_report);

    /* 不 hook tp2_sdk_ioctl / TssSDKIoctl：那是总 switch，误伤心跳/通道 */
    /* 不 hook send 拦 4013：端口层负责 */
}
