#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 与 PC / 隧道同一套特征（精简 C 版）
int sy_contains_4013(const uint8_t *p, size_t n);
int sy_contains_nj_report_0e(const uint8_t *p, size_t n);

#ifdef __cplusplus
}
#endif
