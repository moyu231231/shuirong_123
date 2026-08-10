#import <stdio.h>
#import "TersafeThreadChaos.h"

/*
 * 安全空载：constructor 什么都不做。
 * 注入闪退优先查：dylib 是否盖掉游戏原库、注入目标是否选错。
 */

void sy_install_report_hooks(void) {}
void sy_thread_chaos_start(void) {}

__attribute__((constructor))
static void sy_entry(void) {
    /* 故意空：不打补丁、不挂钩、不弹窗、不链业务逻辑 */
    fprintf(stderr, "[sy_ports] loaded\n");
}
