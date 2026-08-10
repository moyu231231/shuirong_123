#import <Foundation/Foundation.h>
#import "TersafeThreadChaos.h"

__attribute__((constructor))
static void sy_entry(void) {
    /* 稍晚再装检测钩子，先让 DyldHide(101) 生效，降低启动即闪退 */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sy_install_report_hooks();
    });
    for (int i = 3; i <= 8; i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * NSEC_PER_SEC)),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            sy_install_report_hooks();
        });
    }
}
