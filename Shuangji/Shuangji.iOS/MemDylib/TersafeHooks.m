#import <Foundation/Foundation.h>
#import "TersafeThreadChaos.h"

/*
 * 注入闪退排查结论：
 * 1) 自研 syinject 插 LC 会打乱 Mach-O 段偏移 → 已改为 TrollFools insert_dylib
 * 2) 启动期 hook dyld / rcv_anti / 乱挂起线程 → 已全部关掉
 *
 * 本 dylib 默认「空载」：只保证能被正常 dlopen。
 * 报告拦截等业务，等确认目标不再闪退后再开。
 */
__attribute__((constructor))
static void sy_entry(void) {
    (void)0;
}

void sy_thread_chaos_start(void) {}
void sy_install_report_hooks(void) {
    /* 暂不装任何 hook：先验证「空 dylib + 正确签名注入」不闪 */
}
