#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// 禁用：挂起 ACE/MRPCS 线程会闪退
void sy_thread_chaos_start(void);

/// IDA 定点：瘫痪 get_report / rcv_anti / enable_get_report
void sy_install_report_hooks(void);

#ifdef __cplusplus
}
#endif
