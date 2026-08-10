#import <Foundation/Foundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/vm_param.h>
#import <mach-o/dyld.h>
#import <sys/mman.h>
#import <unistd.h>
#import <string.h>
#import "TersafeThreadChaos.h"
#import "fishhook.h"

/*
 * IDA (tersafe.i64) 结论 —— 只动上报/收检测，不动 encrypt/ioctl 全家桶：
 *
 * 举报 / 异常上报（出站）:
 *   sub_37820 循环: tss_get_report_data() → sub_37060(vtable+64 发 GS) → tss_del_report_data
 *   另有 tss_get_report_data3/4 → ioctl(37/59)
 *   导出: _tss_get_report_data* / _TssSDKGetReportData*
 *   内部直调 BL，fishhook 钩不住 → 必须改导出入口机器码
 *
 * 检测下发（入站）:
 *   CS: sub_37130 → tss_sdk_rcv_anti_data
 *   游戏: TssSDKOnRecvData → tss_sdk_rcv_anti_data
 *
 * 已确认空壳: tss_sdk_ischeatpacket 直接 return 0，不用钩
 * 禁用: 线程挂起 / 乱钩 dyld / 钩 encryptpacket（会闪）
 */

#pragma mark - aarch64 stub patch

static int sy_make_rwx(void *addr, size_t len) {
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(PAGE_SIZE - 1);
    size_t off = (uintptr_t)addr - page;
    size_t span = off + len;
    span = (span + PAGE_SIZE - 1) & ~(size_t)(PAGE_SIZE - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, span,
                                  FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        return mprotect((void *)page, span, PROT_READ | PROT_WRITE | PROT_EXEC) == 0 ? 0 : -1;
    }
    return 0;
}

static int sy_make_rx(void *addr, size_t len) {
    uintptr_t page = (uintptr_t)addr & ~(uintptr_t)(PAGE_SIZE - 1);
    size_t off = (uintptr_t)addr - page;
    size_t span = off + len;
    span = (span + PAGE_SIZE - 1) & ~(size_t)(PAGE_SIZE - 1);
    vm_protect(mach_task_self(), page, span, FALSE, VM_PROT_READ | VM_PROT_EXECUTE);
    return 0;
}

/// MOV X0, #0 ; RET
static int sy_patch_ret0(void *fn) {
    if (!fn) return -1;
    uint32_t code[2] = { 0xD2800000u, 0xD65F03C0u };
    if (sy_make_rwx(fn, sizeof(code)) != 0) return -2;
    memcpy(fn, code, sizeof(code));
#if defined(__aarch64__)
    __builtin___clear_cache((char *)fn, (char *)fn + sizeof(code));
#endif
    sy_make_rx(fn, sizeof(code));
    return 0;
}

/// RET only（void / ignore）
static int sy_patch_ret(void *fn) {
    if (!fn) return -1;
    uint32_t code = 0xD65F03C0u;
    if (sy_make_rwx(fn, sizeof(code)) != 0) return -2;
    memcpy(fn, &code, sizeof(code));
#if defined(__aarch64__)
    __builtin___clear_cache((char *)fn, (char *)fn + sizeof(code));
#endif
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

#pragma mark - fishhook 兜底（游戏侧导入）

static void *(*orig_TssSDKGetReportData)(void);
static void *(*orig_tss_get_report_data)(void);

static void *hook_TssSDKGetReportData(void) { return NULL; }
static void *hook_tss_get_report_data(void) { return NULL; }

static void sy_fishhook_report_imports(void) {
    struct rebinding rb[] = {
        { "TssSDKGetReportData",  (void *)hook_TssSDKGetReportData,  (void **)&orig_TssSDKGetReportData },
        { "TssSDKGetReportData2", (void *)hook_TssSDKGetReportData,  NULL },
        { "TssSDKGetReportData3", (void *)hook_TssSDKGetReportData,  NULL },
        { "TssSDKGetReportData4", (void *)hook_TssSDKGetReportData,  NULL },
        { "tss_get_report_data",  (void *)hook_tss_get_report_data,  (void **)&orig_tss_get_report_data },
        { "tss_get_report_data2", (void *)hook_tss_get_report_data,  NULL },
        { "tss_get_report_data3", (void *)hook_tss_get_report_data,  NULL },
        { "tss_get_report_data4", (void *)hook_tss_get_report_data,  NULL },
    };
    rebind_symbols(rb, sizeof(rb) / sizeof(rb[0]));
}

#pragma mark - install

void sy_install_report_hooks(void) {
    static int once = 0;
    if (once) return;
    once = 1;

    /* 出站：抽空报告（举报 / 异常上报 GS+队列） */
    static const char *ret0_syms[] = {
        "tss_get_report_data",
        "tss_get_report_data2",
        "tss_get_report_data3",
        "tss_get_report_data4",
        "TssSDKGetReportData",
        "TssSDKGetReportData2",
        "TssSDKGetReportData3",
        "TssSDKGetReportData4",
        /* 入站检测载荷：直接吞掉，避免再进扫描队列 */
        "tss_sdk_rcv_anti_data",
        "TssSDKOnRecvData",
        NULL
    };
    for (int i = 0; ret0_syms[i]; i++) {
        void *fn = sy_dlsym_tersafe(ret0_syms[i]);
        if (fn) (void)sy_patch_ret0(fn);
    }

    /* 禁止开启「可取报告」开关 */
    void *en = sy_dlsym_tersafe("tss_enable_get_report_data");
    if (en) (void)sy_patch_ret(en);

    /* 游戏若走导入表，再补一层 fishhook */
    sy_fishhook_report_imports();
}

void sy_thread_chaos_start(void) {
    /* 明确禁用：挂起 ACE 线程会秒闪 */
}

__attribute__((constructor))
static void sy_entry(void) {
    /*
     * 延迟安装：等 tersafe / Unity 初始化完再补丁，避免启动期改 TEXT 触发自检闪退。
     * 每 3s 重试找符号，最多约 30s（tersafe 晚加载也能钩上）。
     */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (int i = 0; i < 10; i++) {
            sleep(i == 0 ? 6 : 3);
            void *probe = sy_dlsym_tersafe("tss_get_report_data");
            if (!probe) probe = sy_dlsym_tersafe("TssSDKGetReportData");
            if (probe) {
                sy_install_report_hooks();
                return;
            }
        }
        /* 找不到导出也装 fishhook，覆盖晚绑定导入 */
        sy_fishhook_report_imports();
    });
}
