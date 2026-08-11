/*
 * sy_watch — 监视三角洲进程，settle 后调 sy_kpatch。
 *
 *   sy_watch [--once] [--fg] [--settle N] [--contains a,b,c]
 *
 * 配置：/var/mobile/Library/Caches/com.shuiyong.ports/deploy.conf
 *   auto_mempatch=1
 *   settle=55
 *   contains=tmgp.dfm,DFM,dfm,DeltaForce
 *
 * 状态：
 *   sy_ports_status.txt  — 补丁结果（kpatch 写入）
 *   sy_watch_heartbeat.txt — 守护心跳（证明在跑）
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <time.h>
#include <fcntl.h>
#include <libgen.h>

extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

#define CONF_PATH   "/var/mobile/Library/Caches/com.shuiyong.ports/deploy.conf"
#define STATUS_PATH "/var/mobile/Library/Caches/sy_ports_status.txt"
#define HEART_PATH  "/var/mobile/Library/Caches/sy_watch_heartbeat.txt"
#define LOG_PATH    "/var/mobile/Library/Caches/com.shuiyong.ports/sy_watch.log"
#define PIDFILE     "/var/mobile/Library/Caches/com.shuiyong.ports/sy_watch.pid"
#define DEFAULT_CONTAINS "tmgp.dfm,DFM,dfm,DeltaForce,三角洲"
#define DEFAULT_SETTLE   45
#define MAX_NEEDLES 12

static volatile int g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

static void write_line(const char *path, const char *line) {
    mkdir("/var/mobile/Library/Caches", 0755);
    mkdir("/var/mobile/Library/Caches/com.shuiyong.ports", 0755);
    FILE *f = fopen(path, "w");
    if (!f) return;
    fprintf(f, "%s\n", line);
    fclose(f);
}

static void log_line(const char *line) {
    mkdir("/var/mobile/Library/Caches/com.shuiyong.ports", 0755);
    FILE *f = fopen(LOG_PATH, "a");
    if (!f) return;
    fprintf(f, "%ld %s\n", (long)time(NULL), line);
    fclose(f);
}

static int conf_int(const char *key, int defv) {
    FILE *f = fopen(CONF_PATH, "r");
    if (!f) return defv;
    char line[256];
    int out = defv;
    size_t klen = strlen(key);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
            out = atoi(line + klen + 1);
            break;
        }
    }
    fclose(f);
    return out;
}

static void conf_str(const char *key, char *out, size_t outn, const char *defv) {
    strncpy(out, defv, outn - 1);
    out[outn - 1] = 0;
    FILE *f = fopen(CONF_PATH, "r");
    if (!f) return;
    char line[256];
    size_t klen = strlen(key);
    while (fgets(line, sizeof(line), f)) {
        if (strncmp(line, key, klen) == 0 && line[klen] == '=') {
            char *v = line + klen + 1;
            char *nl = strchr(v, '\n');
            if (nl) *nl = 0;
            strncpy(out, v, outn - 1);
            out[outn - 1] = 0;
            break;
        }
    }
    fclose(f);
}

static int split_needles(char *csv, char *needles[], int maxn) {
    int n = 0;
    char *p = csv;
    while (p && *p && n < maxn) {
        while (*p == ',' || *p == ' ') p++;
        if (!*p) break;
        needles[n++] = p;
        char *c = strchr(p, ',');
        if (c) {
            *c = 0;
            p = c + 1;
        } else break;
    }
    return n;
}

/* 路径或进程短名命中任一 needle */
static int find_pid_needles(char *needles[], int nneedle, char *hit_why, size_t why_n) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0) return -1;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(size);
    if (!procs) return -1;
    if (sysctl(mib, 4, procs, &size, NULL, 0) != 0) {
        free(procs);
        return -1;
    }
    int n = (int)(size / sizeof(struct kinfo_proc));
    int found = -1;
    char pathbuf[1024];
    for (int i = 0; i < n && found < 0; i++) {
        int pid = procs[i].kp_proc.p_pid;
        if (pid <= 1) continue;
        const char *comm = procs[i].kp_proc.p_comm;
        memset(pathbuf, 0, sizeof(pathbuf));
        int has_path = proc_pidpath(pid, pathbuf, sizeof(pathbuf)) > 0;
        for (int k = 0; k < nneedle; k++) {
            if (!needles[k] || !needles[k][0]) continue;
            if (comm && strstr(comm, needles[k])) {
                found = pid;
                if (hit_why) snprintf(hit_why, why_n, "comm=%s needle=%s", comm, needles[k]);
                break;
            }
            if (has_path && strstr(pathbuf, needles[k])) {
                found = pid;
                if (hit_why) snprintf(hit_why, why_n, "path needle=%s", needles[k]);
                break;
            }
        }
    }
    free(procs);
    return found;
}

static int path_exists(const char *p) {
    struct stat st;
    return stat(p, &st) == 0;
}

static const char *resolve_kpatch(void) {
    static const char *cands[] = {
        "/var/mobile/Library/shuiyong/sy_kpatch",
        "/var/mobile/Library/shuiyong/sy_mempatch",
        "/var/jb/usr/local/shuiyong/sy_kpatch",
        "/var/jb/usr/local/shuiyong/sy_mempatch",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        if (path_exists(cands[i])) return cands[i];
    }
    char self[1024];
    if (proc_pidpath(getpid(), self, sizeof(self)) > 0) {
        static char beside[1100];
        char *dup = strdup(self);
        if (dup) {
            char *dir = dirname(dup);
            snprintf(beside, sizeof(beside), "%s/sy_kpatch", dir);
            free(dup);
            if (path_exists(beside)) return beside;
            snprintf(beside, sizeof(beside), "%s/sy_mempatch", dir);
            if (path_exists(beside)) return beside;
        }
    }
    return NULL;
}

static int run_kpatch(int pid) {
    const char *bin = resolve_kpatch();
    if (!bin) {
        char msg[128];
        snprintf(msg, sizeof(msg), "FAIL watch no_kpatch time=%ld", (long)time(NULL));
        write_line(STATUS_PATH, msg);
        log_line(msg);
        return -1;
    }
    char arg[32];
    snprintf(arg, sizeof(arg), "%d", pid);
    char pre[160];
    snprintf(pre, sizeof(pre), "WAIT kpatch_run pid=%d bin=%s time=%ld", pid, bin, (long)time(NULL));
    write_line(STATUS_PATH, pre);
    log_line(pre);

    pid_t c = fork();
    if (c < 0) {
        write_line(STATUS_PATH, "FAIL watch fork");
        return -1;
    }
    if (c == 0) {
        execl(bin, bin, arg, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    waitpid(c, &st, 0);
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    char done[160];
    snprintf(done, sizeof(done), "watch kpatch_done pid=%d exit=%d time=%ld", pid, code, (long)time(NULL));
    log_line(done);
    if (code != 0) {
        /* kpatch 可能已写 FAIL；再补一行确保时间更新 */
        char fail[160];
        snprintf(fail, sizeof(fail), "FAIL kpatch_exit=%d pid=%d time=%ld", code, pid, (long)time(NULL));
        write_line(STATUS_PATH, fail);
    }
    return code;
}

static void daemonize(void) {
    pid_t p = fork();
    if (p < 0) exit(1);
    if (p > 0) exit(0);
    setsid();
    p = fork();
    if (p < 0) exit(1);
    if (p > 0) exit(0);
    chdir("/");
    /* 保留日志文件，不把 stdout 扔进 /dev/null */
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        dup2(fd, 0);
        if (fd > 0) close(fd);
    }
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", (int)getpid());
    write_line(PIDFILE, buf);
}

static void heartbeat(int auto_mp, int pid, const char *extra) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "alive=1 auto=%d game_pid=%d time=%ld %s",
             auto_mp, pid, (long)time(NULL), extra ? extra : "");
    write_line(HEART_PATH, buf);
}

int main(int argc, char **argv) {
    int once = 0;
    int settle = -1;
    int foreground = 0;
    char contains[256];
    conf_str("contains", contains, sizeof(contains), DEFAULT_CONTAINS);
    settle = conf_int("settle", DEFAULT_SETTLE);
    int auto_mp = conf_int("auto_mempatch", 1);

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--once")) once = 1;
        else if (!strcmp(argv[i], "--fg")) foreground = 1;
        else if (!strcmp(argv[i], "--settle") && i + 1 < argc) settle = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--contains") && i + 1 < argc) {
            strncpy(contains, argv[++i], sizeof(contains) - 1);
            contains[sizeof(contains) - 1] = 0;
        }
    }
    if (settle < 8) settle = 8;
    if (settle > 180) settle = 180;

    signal(SIGTERM, on_sig);
    signal(SIGINT, on_sig);

    if (!once && !foreground) daemonize();
    else {
        char buf[32];
        snprintf(buf, sizeof(buf), "%d", (int)getpid());
        write_line(PIDFILE, buf);
    }

    char *needles[MAX_NEEDLES];
    char contains_copy[256];
    strncpy(contains_copy, contains, sizeof(contains_copy) - 1);
    contains_copy[sizeof(contains_copy) - 1] = 0;
    int nneedle = split_needles(contains_copy, needles, MAX_NEEDLES);
    if (nneedle <= 0) {
        needles[0] = "tmgp.dfm";
        needles[1] = "DFM";
        nneedle = 2;
    }

    {
        char arm[200];
        snprintf(arm, sizeof(arm), "WAIT sy_watch armed settle=%d needles=%d time=%ld",
                 settle, nneedle, (long)time(NULL));
        write_line(STATUS_PATH, arm);
        log_line(arm);
        heartbeat(auto_mp, -1, "armed");
    }

    int last_patched = -1;
    while (!g_stop) {
        auto_mp = conf_int("auto_mempatch", 1);
        if (!auto_mp) {
            heartbeat(0, -1, "auto_off");
            if (once) break;
            sleep(5);
            continue;
        }

        char why[128] = "";
        int pid = find_pid_needles(needles, nneedle, why, sizeof(why));
        heartbeat(1, pid, why[0] ? why : (pid > 1 ? "found" : "no_game"));

        if (pid > 1 && pid != last_patched) {
            char msg[200];
            snprintf(msg, sizeof(msg), "WAIT settle pid=%d sec=%d %s time=%ld",
                     pid, settle, why, (long)time(NULL));
            write_line(STATUS_PATH, msg);
            log_line(msg);

            int alive = 1;
            for (int t = 0; t < settle && !g_stop; t++) {
                sleep(1);
                if (find_pid_needles(needles, nneedle, NULL, 0) != pid) {
                    alive = 0;
                    break;
                }
                if ((t % 5) == 0) heartbeat(1, pid, "settling");
            }
            if (g_stop) break;
            if (!alive) {
                snprintf(msg, sizeof(msg), "FAIL watch game_exited_during_settle time=%ld",
                         (long)time(NULL));
                write_line(STATUS_PATH, msg);
                log_line(msg);
                last_patched = -1;
                if (once) break;
                continue;
            }
            run_kpatch(pid);
            last_patched = pid;
            if (once) break;
        } else if (pid <= 1) {
            last_patched = -1;
        }
        if (once) break;
        sleep(2);
    }
    unlink(PIDFILE);
    write_line(HEART_PATH, "alive=0");
    return 0;
}
