#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/// 永久禁用：挂起线程会误伤 Unity
void sy_thread_chaos_start(void);

/// IDA 定点：get_report* + COREREPORT + 总闸10E36C + 扫内存检测
void sy_install_report_hooks(void);

#ifdef __cplusplus
}
#endif
