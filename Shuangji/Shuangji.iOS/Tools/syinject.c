/*
 * Minimal LC_LOAD_DYLIB inserter. Built into the app by package.sh.
 *   syinject inject --exe <macho> --dylib @rpath/ShuiyongMem.dylib
 *   syinject eject  --exe <macho> --name ShuiyongMem.dylib
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>

static int write_all(const char *path, const uint8_t *buf, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) return -1;
    size_t w = fwrite(buf, 1, n, f);
    fclose(f);
    return w == n ? 0 : -1;
}

static uint8_t *read_all(const char *path, size_t *out_n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0) { fclose(f); return NULL; }
    uint8_t *b = (uint8_t *)malloc((size_t)sz);
    if (!b) { fclose(f); return NULL; }
    if (fread(b, 1, (size_t)sz, f) != (size_t)sz) { free(b); fclose(f); return NULL; }
    fclose(f);
    *out_n = (size_t)sz;
    return b;
}

static int has_dylib(uint8_t *base, size_t n, const char *needle) {
    if (n < sizeof(struct mach_header_64)) return 0;
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (mh->magic != MH_MAGIC_64) return 0;
    uint8_t *p = base + sizeof(*mh);
    uint8_t *end = base + n;
    for (uint32_t i = 0; i < mh->ncmds && p + 8 <= end; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmdsize < 8 || p + lc->cmdsize > end) break;
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
            struct dylib_command *dc = (struct dylib_command *)lc;
            const char *s = (const char *)lc + dc->dylib.name.offset;
            if (s < (const char *)end && strstr(s, needle)) return 1;
        }
        p += lc->cmdsize;
    }
    return 0;
}

static int inject_one(uint8_t **pbuf, size_t *pn, const char *install_name, int weak) {
    uint8_t *base = *pbuf;
    size_t n = *pn;
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (n < sizeof(*mh) || mh->magic != MH_MAGIC_64) {
        fprintf(stderr, "need thin arm64 mach-o\n");
        return -1;
    }
    if (has_dylib(base, n, "ShuiyongMem.dylib")) return 0;

    size_t namelen = strlen(install_name) + 1;
    size_t cmdsize = sizeof(struct dylib_command) + ((namelen + 7) & ~7ull);
    size_t old_n = n;
    size_t insert_at = sizeof(*mh) + mh->sizeofcmds;
    size_t new_n = old_n + cmdsize;
    uint8_t *nb = (uint8_t *)realloc(base, new_n);
    if (!nb) return -1;
    base = nb; *pbuf = nb; *pn = new_n;
    mh = (struct mach_header_64 *)base;

    memmove(base + insert_at + cmdsize, base + insert_at, old_n - insert_at);
    memset(base + insert_at, 0, cmdsize);
    struct dylib_command *dc = (struct dylib_command *)(base + insert_at);
    dc->cmd = weak ? LC_LOAD_WEAK_DYLIB : LC_LOAD_DYLIB;
    dc->cmdsize = (uint32_t)cmdsize;
    dc->dylib.name.offset = (uint32_t)sizeof(struct dylib_command);
    dc->dylib.timestamp = 2;
    dc->dylib.current_version = 0x10000;
    dc->dylib.compatibility_version = 0x10000;
    memcpy((char *)dc + sizeof(struct dylib_command), install_name, namelen);

    mh->ncmds += 1;
    mh->sizeofcmds += (uint32_t)cmdsize;
    return 0;
}

static int eject_one(uint8_t *base, size_t n, const char *name) {
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (n < sizeof(*mh) || mh->magic != MH_MAGIC_64) return -1;
    uint8_t *p = base + sizeof(*mh);
    uint8_t *end = base + n;
    for (uint32_t i = 0; i < mh->ncmds && p + 8 <= end; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmdsize < 8 || p + lc->cmdsize > end) break;
        if (lc->cmd == LC_LOAD_DYLIB || lc->cmd == LC_LOAD_WEAK_DYLIB) {
            struct dylib_command *dc = (struct dylib_command *)lc;
            char *s = (char *)lc + dc->dylib.name.offset;
            if (s < (char *)end && strstr(s, name)) {
                size_t L = strlen(s);
                memset(s, 0, L);
                return 0;
            }
        }
        p += lc->cmdsize;
    }
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "syinject inject --exe PATH --dylib @rpath/ShuiyongMem.dylib\n");
        return 1;
    }
    const char *mode = argv[1];
    const char *exe = NULL;
    const char *dylib = "@rpath/ShuiyongMem.dylib";
    const char *name = "ShuiyongMem.dylib";
    int weak = 0;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--exe") && i + 1 < argc) exe = argv[++i];
        else if (!strcmp(argv[i], "--dylib") && i + 1 < argc) dylib = argv[++i];
        else if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--weak")) weak = 1;
        else if (!strcmp(argv[i], "--app") || !strcmp(argv[i], "--rpath")) {
            if (i + 1 < argc) i++;
        }
    }
    if (!exe) { fprintf(stderr, "need --exe\n"); return 1; }

    size_t n = 0;
    uint8_t *buf = read_all(exe, &n);
    if (!buf) { perror("read"); return 1; }

    int rc = 1;
    if (!strcmp(mode, "inject")) {
        char tmp[512];
        const char *install = dylib;
        if (strchr(dylib, '/')) {
            const char *base = strrchr(dylib, '/');
            base = base ? base + 1 : dylib;
            snprintf(tmp, sizeof(tmp), "@rpath/%s", base);
            install = tmp;
        }
        rc = inject_one(&buf, &n, install, weak);
        if (rc == 0) rc = write_all(exe, buf, n);
    } else if (!strcmp(mode, "eject")) {
        rc = eject_one(buf, n, name);
        if (rc == 0) rc = write_all(exe, buf, n);
    }
    free(buf);
    return rc ? 1 : 0;
}
