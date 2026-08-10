#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import "TersafeThreadChaos.h"

/*
 * 安全空载模式（排查闪退用）
 *
 * 已关掉、不再碰：
 *   - 改 tersafe TEXT / RVA 补丁（vm_protect）
 *   - fishhook 扫全镜像（Unity 很脆）
 *   - UIWindow / UIAlert（抢场景易崩）
 *   - send/write、挂起线程
 *
 * 本文件只在加载后打一条日志，确认「注入本身不闪」。
 * 拦上报先靠隧道/网关 4013；确认稳定后再加软钩子。
 */

void sy_install_report_hooks(void) {
    /* 故意空：当前不加任何钩子 */
}

void sy_thread_chaos_start(void) {
    /* 永久空 */
}

__attribute__((constructor))
static void sy_entry(void) {
    /* constructor 里只丢后台任务，不做任何补丁/UI */
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sleep(5);
        NSLog(@"[水溶C] ApolloNetService loaded (safe no-op mode)");
    });
}
