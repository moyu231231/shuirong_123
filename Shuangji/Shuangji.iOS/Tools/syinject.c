/*
 * Root helper: copy dylib into app Frameworks + insert LC_LOAD_DYLIB.
 * Must be launched via persona root (SYSpawnRoot).
 *
 *   syinject deploy --app <App.app> --src <ShuiyongMem.dylib> [--exe <macho>]
 *   syinject eject  --app <App.app> [--exe <macho>] --name ShuiyongMem.dylib
 *   syinject inject --exe <macho> --dylib @rpath/ShuiyongMem.dylib
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <unistd.h>
#include <dirent.h>
#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <mach/machine.h>

/* iOS 有 libproc，SDK 头未必暴露 */
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

static int write_all(const char *path, const uint8_t *buf, size_t n) {
    FILE *f = fopen(path, "wb");
    if (!f) { perror(path); return -1; }
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

static int copy_file(const char *src, const char *dst) {
    size_t n = 0;
    uint8_t *b = read_all(src, &n);
    if (!b) { perror(src); return -1; }
    int rc = write_all(dst, b, n);
    free(b);
    if (rc == 0) chmod(dst, 0644);
    return rc;
}

static int mkdir_p(const char *path) {
    char tmp[1024];
    size_t len = strlen(path);
    if (len >= sizeof(tmp)) return -1;
    memcpy(tmp, path, len + 1);
    for (char *p = tmp + 1; *p; p++) {
        if (*p == '/') {
            *p = 0;
            mkdir(tmp, 0755);
            *p = '/';
        }
    }
    return mkdir(tmp, 0755) == 0 || errno == EEXIST ? 0 : -1;
}

static int is_encrypted_slice(uint8_t *base, size_t n) {
    if (n < sizeof(struct mach_header_64)) return 1;
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    if (mh->magic != MH_MAGIC_64) return 1;
    uint8_t *p = base + sizeof(*mh);
    uint8_t *end = base + n;
    for (uint32_t i = 0; i < mh->ncmds && p + 8 <= end; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmdsize < 8 || p + lc->cmdsize > end) break;
        if (lc->cmd == LC_ENCRYPTION_INFO_64) {
            struct encryption_info_command_64 *ei = (struct encryption_info_command_64 *)lc;
            return ei->cryptid != 0;
        }
        if (lc->cmd == LC_ENCRYPTION_INFO) {
            struct encryption_info_command *ei = (struct encryption_info_command *)lc;
            return ei->cryptid != 0;
        }
        p += lc->cmdsize;
    }
    return 0;
}

/* Prefer thin arm64; if FAT, pick arm64 slice into new buffer (caller frees). */
static uint8_t *load_thin_arm64(const char *path, size_t *out_n, int *was_fat) {
    size_t n = 0;
    uint8_t *buf = read_all(path, &n);
    if (!buf) return NULL;
    *was_fat = 0;
    uint32_t magic = *(uint32_t *)buf;
    if (magic == MH_MAGIC_64) {
        *out_n = n;
        return buf;
    }
    if (magic != FAT_MAGIC && magic != FAT_CIGAM) {
        free(buf);
        return NULL;
    }
    *was_fat = 1;
    struct fat_header fh;
    memcpy(&fh, buf, sizeof(fh));
    uint32_t nfat = (magic == FAT_CIGAM) ? __builtin_bswap32(fh.nfat_arch) : fh.nfat_arch;
    struct fat_arch *archs = (struct fat_arch *)(buf + sizeof(struct fat_header));
    for (uint32_t i = 0; i < nfat; i++) {
        uint32_t cputype = archs[i].cputype;
        uint32_t offset = archs[i].offset;
        uint32_t size = archs[i].size;
        if (magic == FAT_CIGAM) {
            cputype = __builtin_bswap32(cputype);
            offset = __builtin_bswap32(offset);
            size = __builtin_bswap32(size);
        }
        if (cputype == CPU_TYPE_ARM64 && offset + size <= n) {
            uint8_t *slice = (uint8_t *)malloc(size);
            if (!slice) { free(buf); return NULL; }
            memcpy(slice, buf + offset, size);
            free(buf);
            *out_n = size;
            return slice;
        }
    }
    free(buf);
    return NULL;
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

static int ensure_rpath(uint8_t **pbuf, size_t *pn, const char *rpath) {
    uint8_t *base = *pbuf;
    size_t n = *pn;
    struct mach_header_64 *mh = (struct mach_header_64 *)base;
    uint8_t *p = base + sizeof(*mh);
    uint8_t *end = base + n;
    for (uint32_t i = 0; i < mh->ncmds && p + 8 <= end; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmdsize < 8 || p + lc->cmdsize > end) break;
        if (lc->cmd == LC_RPATH) {
            struct rpath_command *rc = (struct rpath_command *)lc;
            const char *s = (const char *)lc + rc->path.offset;
            if (s < (const char *)end && strcmp(s, rpath) == 0) return 0;
        }
        p += lc->cmdsize;
    }
    size_t namelen = strlen(rpath) + 1;
    size_t cmdsize = sizeof(struct rpath_command) + ((namelen + 7) & ~7ull);
    size_t insert_at = sizeof(*mh) + mh->sizeofcmds;
    size_t new_n = n + cmdsize;
    uint8_t *nb = (uint8_t *)realloc(base, new_n);
    if (!nb) return -1;
    base = nb; *pbuf = nb; *pn = new_n;
    mh = (struct mach_header_64 *)base;
    memmove(base + insert_at + cmdsize, base + insert_at, n - insert_at);
    memset(base + insert_at, 0, cmdsize);
    struct rpath_command *rc = (struct rpath_command *)(base + insert_at);
    rc->cmd = LC_RPATH;
    rc->cmdsize = (uint32_t)cmdsize;
    rc->path.offset = (uint32_t)sizeof(struct rpath_command);
    memcpy((char *)rc + sizeof(struct rpath_command), rpath, namelen);
    mh->ncmds += 1;
    mh->sizeofcmds += (uint32_t)cmdsize;
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
    if (is_encrypted_slice(base, n)) {
        fprintf(stderr, "encrypted mach-o\n");
        return -1;
    }
    if (has_dylib(base, n, "sy_ports.dylib")) return 0;
    if (has_dylib(base, n, "ShuiyongMem.dylib")) return 0;
    if (has_dylib(base, n, "ApolloNetService.dylib")) return 0;
    if (ensure_rpath(pbuf, pn, "@executable_path/Frameworks") != 0) return -1;
    base = *pbuf; n = *pn; mh = (struct mach_header_64 *)base;

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

static int patch_macho(const char *path, int do_inject, const char *install_or_name, int weak) {
    int was_fat = 0;
    size_t n = 0;
    uint8_t *buf = load_thin_arm64(path, &n, &was_fat);
    if (!buf) { fprintf(stderr, "read fail %s\n", path); return -1; }
    if (was_fat) {
        fprintf(stderr, "fat binary not rewritten in-place: %s\n", path);
        free(buf);
        return -1;
    }
    int rc;
    if (do_inject) rc = inject_one(&buf, &n, install_or_name, weak);
    else rc = eject_one(buf, n, install_or_name);
    if (rc == 0) rc = write_all(path, buf, n);
    free(buf);
    return rc;
}

static int plist_executable(const char *app, char *out, size_t outn) {
    char plist[1024];
    snprintf(plist, sizeof(plist), "%s/Info.plist", app);
    /* crude scan for CFBundleExecutable string – prefer using path from caller */
    FILE *f = fopen(plist, "rb");
    if (!f) return -1;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz <= 0 || sz > 2 * 1024 * 1024) { fclose(f); return -1; }
    char *buf = (char *)malloc((size_t)sz + 1);
    if (!buf) { fclose(f); return -1; }
    fread(buf, 1, (size_t)sz, f);
    fclose(f);
    buf[sz] = 0;
    const char *key = "CFBundleExecutable";
    char *p = strstr(buf, key);
    if (!p) { free(buf); return -1; }
    p = strstr(p, "<string>");
    if (!p) { free(buf); return -1; }
    p += 8;
    char *e = strstr(p, "</string>");
    if (!e || (size_t)(e - p) >= outn) { free(buf); return -1; }
    memcpy(out, p, (size_t)(e - p));
    out[e - p] = 0;
    free(buf);
    return 0;
}

static int is_blocked_framework(const char *name) {
    /* 勿注入 ACE/腾讯通道库；盖同名 dylib（如 ApolloNetService）会秒闪 */
    static const char *bad[] = {
        "tersafe", "Tersafe", "TERSAFE",
        "ACE", "ace_", "TP.framework", "TPF", "tprt",
        "TSS", "tss", "AntiCheat", "mrpcs", "MRPCS",
        "Apollo", "apollo", "GCloud", "gcloud", "MSDK",
        "TGPA", "tp2", "behavio", "Beacon", "QQConnect",
        NULL
    };
    for (int i = 0; bad[i]; i++) {
        if (strstr(name, bad[i])) return 1;
    }
    return 0;
}

static int try_candidate(const char *path, char *best, size_t bestn, size_t *best_size, int prefer) {
    size_t n = 0;
    int was_fat = 0;
    uint8_t *buf = load_thin_arm64(path, &n, &was_fat);
    if (!buf) return 0;
    /* fat 已抽出 arm64 slice；只要 slice 未加密即可（insert_dylib 也能处理 fat） */
    int ok = !is_encrypted_slice(buf, n);
    free(buf);
    if (!ok) return 0;
    struct stat st;
    if (stat(path, &st) != 0) return 0;
    /* prefer=1：优先大体积游戏框架（Unity 等）；否则取较小可用 */
    if (prefer) {
        if ((size_t)st.st_size > *best_size) {
            snprintf(best, bestn, "%s", path);
            *best_size = (size_t)st.st_size;
        }
    } else {
        if (*best_size == 0 || (size_t)st.st_size < *best_size) {
            snprintf(best, bestn, "%s", path);
            *best_size = (size_t)st.st_size;
        }
    }
    return 1;
}

static int find_inject_target(const char *app, char *out, size_t outn) {
    char best[1024] = {0};
    size_t best_size = 0;
    char fwkroot[1024];
    snprintf(fwkroot, sizeof(fwkroot), "%s/Frameworks", app);

    /* 第一轮：优先 UnityFramework / Ill2Cpp 等大框架 */
    DIR *d = opendir(fwkroot);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            if (!strstr(ent->d_name, ".framework")) continue;
            if (is_blocked_framework(ent->d_name)) continue;
            char name[256];
            snprintf(name, sizeof(name), "%s", ent->d_name);
            char *dot = strstr(name, ".framework");
            if (dot) *dot = 0;
            int prefer = 0;
            /* 只优先游戏引擎本体；绝不要优先 Apollo/GCloud */
            if (strstr(name, "UnityFramework") || strstr(name, "Unity") ||
                strstr(name, "Il2Cpp") || strstr(name, "GameAssembly") ||
                strstr(name, "UE4") || strstr(name, "Unreal") ||
                strstr(name, "ShadowTracker") || strstr(name, "ProjectN"))
                prefer = 1;
            char cand[1200];
            snprintf(cand, sizeof(cand), "%s/%s.framework/%s", fwkroot, name, name);
            if (prefer)
                try_candidate(cand, best, sizeof(best), &best_size, 1);
        }
        closedir(d);
    }
    if (best[0]) {
        snprintf(out, outn, "%s", best);
        return 0;
    }

    /* 第二轮：任意非封锁 framework */
    best_size = 0;
    d = opendir(fwkroot);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            if (!strstr(ent->d_name, ".framework")) continue;
            if (is_blocked_framework(ent->d_name)) continue;
            char name[256];
            snprintf(name, sizeof(name), "%s", ent->d_name);
            char *dot = strstr(name, ".framework");
            if (dot) *dot = 0;
            char cand[1200];
            snprintf(cand, sizeof(cand), "%s/%s.framework/%s", fwkroot, name, name);
            try_candidate(cand, best, sizeof(best), &best_size, 0);
        }
        closedir(d);
    }
    if (best[0]) {
        snprintf(out, outn, "%s", best);
        return 0;
    }

    /* 第三轮：Frameworks 根目录裸 dylib（TrollFools 兼容） */
    best_size = 0;
    d = opendir(fwkroot);
    if (d) {
        struct dirent *ent;
        while ((ent = readdir(d)) != NULL) {
            size_t nl = strlen(ent->d_name);
            if (nl < 7 || strcmp(ent->d_name + nl - 6, ".dylib") != 0) continue;
            if (is_blocked_framework(ent->d_name)) continue;
            if (!strncmp(ent->d_name, "libswift", 8)) continue;
            if (!strcmp(ent->d_name, "sy_ports.dylib")) continue;
            if (!strcmp(ent->d_name, "ShuiyongMem.dylib")) continue;
            if (!strcmp(ent->d_name, "ApolloNetService.dylib")) continue;
            char cand[1200];
            snprintf(cand, sizeof(cand), "%s/%s", fwkroot, ent->d_name);
            try_candidate(cand, best, sizeof(best), &best_size, 1);
        }
        closedir(d);
    }
    if (best[0]) {
        snprintf(out, outn, "%s", best);
        return 0;
    }

    /* 最后才碰主程序（加密主程序绝不能选） */
    char exe[256];
    if (plist_executable(app, exe, sizeof(exe)) == 0) {
        char cand[1200];
        snprintf(cand, sizeof(cand), "%s/%s", app, exe);
        if (try_candidate(cand, best, sizeof(best), &best_size, 0) && best[0]) {
            snprintf(out, outn, "%s", best);
            return 0;
        }
    }
    return -1;
}

static void chown_installd(const char *path) {
    /* 33 = _installd */
    chown(path, 33, 33);
}

/* 按路径子串或进程短名找 PID。stdout 只打一个 pid */
static int find_pid_contains(const char *needle) {
    if (!needle || !needle[0]) return -1;
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t len = 0;
    if (sysctl(mib, 4, NULL, &len, NULL, 0) != 0 || len == 0) return -1;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &len, NULL, 0) != 0) {
        free(procs);
        return -1;
    }
    int n = (int)(len / sizeof(struct kinfo_proc));
    int found = -1;
    char pathbuf[1024];
    for (int i = 0; i < n; i++) {
        int pid = procs[i].kp_proc.p_pid;
        if (pid <= 1) continue;
        if (procs[i].kp_proc.p_comm[0] && strstr(procs[i].kp_proc.p_comm, needle)) {
            found = pid;
            break;
        }
        memset(pathbuf, 0, sizeof(pathbuf));
        if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) <= 0) continue;
        if (strstr(pathbuf, needle)) {
            found = pid;
            break;
        }
    }
    free(procs);
    return found;
}

static int name_is_device_id(const char *n) {
    if (!n || !*n) return 0;
    static const char *keys[] = {
        "TssSDK", "tss_sdk", "tsssdk", "tersafe", "Tersafe",
        "DeviceID", "deviceid", "IDFV", "idfv", "iDevIDFV",
        "mrpcs", "MRPCS", "anticheat", "AntiCheat", "ano_tmp",
        "gcloud", "GCloud", "tdm_", "TDM", "ACE_", NULL
    };
    for (int i = 0; keys[i]; i++) {
        if (strstr(n, keys[i])) return 1;
    }
    return 0;
}

static int cleandevid_walk(const char *dir, int depth, int *removed) {
    if (!dir || depth > 8) return 0;
    DIR *d = opendir(dir);
    if (!d) return 0;
    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        if (!strcmp(ent->d_name, ".") || !strcmp(ent->d_name, "..")) continue;
        char path[1400];
        snprintf(path, sizeof(path), "%s/%s", dir, ent->d_name);
        struct stat st;
        if (lstat(path, &st) != 0) continue;
        if (S_ISDIR(st.st_mode)) {
            cleandevid_walk(path, depth + 1, removed);
            /* 空目录 / 命中名的目录也删 */
            if (name_is_device_id(ent->d_name)) {
                /* 再扫一层后尝试 rmdir 树：简单 unlink 子后 rmdir */
                DIR *d2 = opendir(path);
                if (d2) {
                    struct dirent *e2;
                    while ((e2 = readdir(d2)) != NULL) {
                        if (!strcmp(e2->d_name, ".") || !strcmp(e2->d_name, "..")) continue;
                        char p2[1500];
                        snprintf(p2, sizeof(p2), "%s/%s", path, e2->d_name);
                        unlink(p2);
                    }
                    closedir(d2);
                }
                if (rmdir(path) == 0 && removed) (*removed)++;
            }
        } else if (S_ISREG(st.st_mode) || S_ISLNK(st.st_mode)) {
            if (name_is_device_id(ent->d_name)) {
                if (unlink(path) == 0 && removed) (*removed)++;
            }
        }
    }
    closedir(d);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "syinject mkdir|cp|rm|chown33|exists|cleandevid|enc|find|pid|cat|deploy|eject|inject ...\n");
        return 1;
    }
    const char *mode = argv[1];
    const char *app = NULL;
    const char *src = NULL;
    const char *dst = NULL;
    const char *path = NULL;
    const char *exe = NULL;
    const char *dylib = "@rpath/sy_ports.dylib";
    const char *name = "sy_ports.dylib";
    const char *contains = NULL;
    int weak = 1;
    for (int i = 2; i < argc; i++) {
        if (!strcmp(argv[i], "--app") && i + 1 < argc) app = argv[++i];
        else if (!strcmp(argv[i], "--src") && i + 1 < argc) src = argv[++i];
        else if (!strcmp(argv[i], "--dst") && i + 1 < argc) dst = argv[++i];
        else if (!strcmp(argv[i], "--path") && i + 1 < argc) path = argv[++i];
        else if (!strcmp(argv[i], "--exe") && i + 1 < argc) exe = argv[++i];
        else if (!strcmp(argv[i], "--dylib") && i + 1 < argc) dylib = argv[++i];
        else if (!strcmp(argv[i], "--name") && i + 1 < argc) name = argv[++i];
        else if (!strcmp(argv[i], "--contains") && i + 1 < argc) contains = argv[++i];
        else if (!strcmp(argv[i], "--weak")) weak = 1;
        else if (!strcmp(argv[i], "--strong")) weak = 0;
        else if (!strcmp(argv[i], "--rpath") && i + 1 < argc) i++;
    }

    /* 文件系统小工具：以 root persona spawn 后在本进程内读写，不依赖 /bin/cp */
    if (!strcmp(mode, "mkdir")) {
        if (!path) { fprintf(stderr, "need --path\n"); return 1; }
        if (mkdir_p(path) != 0) { perror("mkdir"); return 2; }
        return 0;
    }
    if (!strcmp(mode, "cp")) {
        if (!src || !dst) { fprintf(stderr, "need --src --dst\n"); return 1; }
        unlink(dst);
        if (copy_file(src, dst) != 0) { perror("cp"); return 2; }
        chown_installd(dst);
        return 0;
    }
    if (!strcmp(mode, "rm")) {
        if (!path) { fprintf(stderr, "need --path\n"); return 1; }
        unlink(path);
        return 0;
    }
    if (!strcmp(mode, "chown33")) {
        if (!path) { fprintf(stderr, "need --path\n"); return 1; }
        chown_installd(path);
        return 0;
    }
    if (!strcmp(mode, "exists")) {
        if (!path) { fprintf(stderr, "need --path\n"); return 1; }
        return access(path, F_OK) == 0 ? 0 : 1;
    }
    /* 清理应用沙盒内 ACE/TSS 设备标识缓存（须先杀进程） */
    if (!strcmp(mode, "cleandevid")) {
        if (!path) { fprintf(stderr, "need --path <dataContainer>\n"); return 1; }
        if (access(path, F_OK) != 0) { fprintf(stderr, "no container\n"); return 2; }
        int removed = 0;
        static const char *subs[] = {
            "Library/Preferences", "Library/Caches", "Library/Application Support",
            "Documents", "tmp", "Library", NULL
        };
        for (int i = 0; subs[i]; i++) {
            char sub[1400];
            snprintf(sub, sizeof(sub), "%s/%s", path, subs[i]);
            cleandevid_walk(sub, 0, &removed);
        }
        /* 根下零散文件 */
        cleandevid_walk(path, 0, &removed);
        fprintf(stdout, "removed=%d\n", removed);
        return 0;
    }
    /* 动态注入：按路径子串查进程 PID */
    if (!strcmp(mode, "pid")) {
        const char *key = contains;
        if (!key && app) key = app;
        if (!key && path) key = path;
        if (!key) { fprintf(stderr, "need --contains <substr> or --app <pathfrag>\n"); return 1; }
        int pid = find_pid_contains(key);
        if (pid <= 0) {
            fprintf(stderr, "not found\n");
            return 1;
        }
        fprintf(stdout, "%d\n", pid);
        return 0;
    }
    /* 打印文件内容到 stdout（给 App 查补丁状态用） */
    if (!strcmp(mode, "cat")) {
        if (!path) { fprintf(stderr, "need --path\n"); return 1; }
        FILE *f = fopen(path, "rb");
        if (!f) { perror(path); return 2; }
        char buf[4096];
        size_t n;
        while ((n = fread(buf, 1, sizeof(buf), f)) > 0)
            fwrite(buf, 1, n, stdout);
        fclose(f);
        return 0;
    }
    /* 0=未加密可注入 1=加密 2=无法解析 */
    if (!strcmp(mode, "enc")) {
        if (!path) { fprintf(stderr, "need --path\n"); return 2; }
        size_t n = 0;
        int was_fat = 0;
        uint8_t *buf = load_thin_arm64(path, &n, &was_fat);
        if (!buf) {
            fprintf(stderr, "unreadable\n");
            return 2;
        }
        int enc = is_encrypted_slice(buf, n);
        free(buf);
        if (enc) {
            fprintf(stdout, "encrypted\n");
            return 1;
        }
        fprintf(stdout, "ok%s\n", was_fat ? " fat" : "");
        return 0;
    }
    /* 打印最佳未加密注入目标路径 */
    if (!strcmp(mode, "find")) {
        if (!app) { fprintf(stderr, "need --app\n"); return 1; }
        char target[1200];
        if (find_inject_target(app, target, sizeof(target)) != 0) {
            fprintf(stderr, "no injectable mach-o\n");
            return 1;
        }
        fprintf(stdout, "%s\n", target);
        return 0;
    }

    if (!strcmp(mode, "deploy")) {
        if (!app || !src) { fprintf(stderr, "need --app --src\n"); return 1; }
        char fwk[1100];
        snprintf(fwk, sizeof(fwk), "%s/Frameworks", app);
        if (mkdir_p(fwk) != 0) { perror("mkdir Frameworks"); return 2; }
        char dest[1200];
        snprintf(dest, sizeof(dest), "%s/%s", fwk, name);
        unlink(dest);
        if (copy_file(src, dest) != 0) return 3;
        chown_installd(dest);

        char target[1200];
        if (exe) snprintf(target, sizeof(target), "%s", exe);
        else if (find_inject_target(app, target, sizeof(target)) != 0) {
            fprintf(stderr, "no injectable mach-o\n");
            return 4;
        }
        char install[512];
        snprintf(install, sizeof(install), "@rpath/%s", name);
        if (patch_macho(target, 1, install, weak) != 0) return 5;
        chown_installd(target);

        char mark[1200];
        snprintf(mark, sizeof(mark), "%s/.sy_injected", fwk);
        FILE *mf = fopen(mark, "wb");
        if (mf) { fputs(target, mf); fclose(mf); chown_installd(mark); }
        /* 输出：ok <macho> —— 上层拿去做 ldid + ct_bypass */
        fprintf(stdout, "ok %s\n", target);
        return 0;
    }

    if (!strcmp(mode, "eject")) {
        if (!app) { fprintf(stderr, "need --app\n"); return 1; }
        char fwk[1100];
        snprintf(fwk, sizeof(fwk), "%s/Frameworks", app);
        char dest[1200];
        snprintf(dest, sizeof(dest), "%s/%s", fwk, name);
        unlink(dest);
        char mark[1200];
        snprintf(mark, sizeof(mark), "%s/.sy_injected", fwk);
        unlink(mark);

        char target[1200];
        if (exe) snprintf(target, sizeof(target), "%s", exe);
        else if (find_inject_target(app, target, sizeof(target)) != 0) return 0;
        patch_macho(target, 0, name, 0);
        return 0;
    }

    if (!strcmp(mode, "inject")) {
        if (!exe) { fprintf(stderr, "need --exe\n"); return 1; }
        char install[512];
        const char *use = dylib;
        if (strchr(dylib, '/')) {
            const char *base = strrchr(dylib, '/');
            base = base ? base + 1 : dylib;
            snprintf(install, sizeof(install), "@rpath/%s", base);
            use = install;
        }
        return patch_macho(exe, 1, use, weak) == 0 ? 0 : 1;
    }

    fprintf(stderr, "unknown mode\n");
    return 1;
}
