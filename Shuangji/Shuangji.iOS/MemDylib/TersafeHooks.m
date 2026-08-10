#import <Foundation/Foundation.h>
#import "TersafeThreadChaos.h"

__attribute__((constructor))
static void sy_entry(void) {
    sy_install_report_hooks();
    sy_thread_chaos_start();

    /* tersafe 常延迟加载：短暂重绑 */
    for (int i = 1; i <= 5; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            sy_install_report_hooks();
        });
    }
}
