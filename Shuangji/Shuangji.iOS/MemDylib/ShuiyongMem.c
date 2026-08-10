#include "ShuiyongMem.h"
#include <string.h>

static int find_pat(const uint8_t *p, size_t n, const uint8_t *pat, size_t plen) {
    if (!p || n < plen) return 0;
    size_t lim = n > 65536 ? 65536 : n;
    for (size_t i = 0; i + plen <= lim; i++) {
        if (memcmp(p + i, pat, plen) == 0) return 1;
    }
    return 0;
}

int sy_contains_4013(const uint8_t *p, size_t n) {
    static const uint8_t pat[] = {0x33, 0x66, 0x00, 0x0B, 0x00, 0x0C, 0x40, 0x13};
    return find_pat(p, n, pat, sizeof(pat));
}

int sy_contains_nj_report_0e(const uint8_t *p, size_t n) {
    static const uint8_t head[] = {0x01, 0x00, 0x00, 0x0E};
    if (!p || n < 20) return 0;
    size_t lim = n > 65536 ? 65536 : n;
    for (size_t i = 0; i + 4 <= lim; i++) {
        if (memcmp(p + i, head, 4) != 0) continue;
        size_t end = i + 64;
        if (end > lim) end = lim;
        for (size_t j = i + 4; j + 1 < end; j++) {
            if (p[j] == 0x0A && p[j + 1] == 0x92) return 1;
        }
    }
    return 0;
}
