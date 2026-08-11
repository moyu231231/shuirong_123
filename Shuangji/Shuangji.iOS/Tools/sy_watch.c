/*
 * sy_watch — Dopamine/TrollStore 下监视三角洲进程，settle 后调 sy_kpatch。
 *
 *   sy_watch [--once] [--settle N] [--contains substr]
 *
 * 配置（可选，键=值）：
 *   /var/mobile/Library/Caches/com.shuiyong.ports/deploy.conf
 *     auto_mempatch=1
 *     settle=55
 *     contains=tmgp.dfm
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
#define PIDFILE     "/var/mobile/Library/Caches/com.shuiyong.ports/sy_watch.pid"
#define DEFAULT_CONTAINS "tmgp.dfm"
#define DEFAULT_SETTLE   55

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

static int find_pid_contains(const char *needle) {
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
    for (int i = 0; i < n; i++) {
        int pid = procs[i].kp_proc.p_pid;
        if (pid <= 1) continue;
        if (proc_pidpath(pid, pathbuf, sizeof(pathbuf)) <= 0) continue;
        if (strstr(pathbuf, needle)) {
            found = pid;
            break;
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
        /* mobile 优先：RootHide 无固定 /var/jb */
        "/var/mobile/Library/shuiyong/sy_kpatch",
        "/var/mobile/Library/shuiyong/sy_mempatch",
        "/var/jb/usr/local/shuiyong/sy_kpatch",
        "/var/jb/usr/local/shuiyong/sy_mempatch",
        NULL
    };
    for (int i = 0; cands[i]; i++) {
        if (path_exists(cands[i])) return cands[i];
    }
    /* 与 sy_watch 同目录 */
    char self[1024];
    uint32_t sz = sizeof(self);
    if (proc_pidpath(getpid(), self, sz) > 0) {
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
        write_line(STATUS_PATH, "FAIL watch no_kpatch");
        fprintf(stderr, "sy_watch: no sy_kpatch\n");
        return -1;
    }
    char arg[32];
    snprintf(arg, sizeof(arg), "%d", pid);
    pid_t c = fork();
    if (c < 0) return -1;
    if (c == 0) {
        execl(bin, bin, arg, (char *)NULL);
        _exit(127);
    }
    int st = 0;
    waitpid(c, &st, 0);
    int code = WIFEXITED(st) ? WEXITSTATUS(st) : -1;
    fprintf(stdout, "sy_watch: kpatch pid=%d exit=%d via %s\n", pid, code, bin);
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
    int fd = open("/dev/null", O_RDWR);
    if (fd >= 0) {
        dup2(fd, 0);
        dup2(fd, 1);
        dup2(fd, 2);
        if (fd > 2) close(fd);
    }
    char buf[32];
    snprintf(buf, sizeof(buf), "%d", (int)getpid());
    write_line(PIDFILE, buf);
}

int main(int argc, char **argv) {
    int once = 0;
    int settle = -1;
    int foreground = 0;
    char contains[128];
    conf_str("contains", contains, sizeof(contains), DEFAULT_CONTAINS);
    settle = conf_int("settle", DEFAULT_SETTLE);
    int auto_mp = conf_int("auto_mempatch", 1);

    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--once")) once = 1;
        else if (!strcmp(argv[i], "--fg")) foreground = 1;
        else if (!strcmp(argv[i], "--settle") && i + 1 < argc) settle = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--contains") && i + 1 < argc) {
            strncpy(contains, argv[++i], sizeof(contains) - 1);
        }
    }
    if (settle < 8) settle = 8;
    if (settle > 180) settle = 180;

    signal(SIGTERM, on_sig);
    signal(SIGINT, on_sig);

    if (!once && !foreground) daemonize();

    fprintf(stdout, "sy_watch start auto=%d settle=%d contains=%s\n",
            auto_mp, settle, contains);
    write_line(STATUS_PATH, "WAIT sy_watch armed");

    int last_patched = -1;
    while (!g_stop) {
        auto_mp = conf_int("auto_mempatch", 1);
        if (!auto_mp) {
            if (once) break;
            sleep(5);
            continue;
        }
        int pid = find_pid_contains(contains);
        if (pid > 1 && pid != last_patched) {
            char msg[160];
            snprintf(msg, sizeof(msg), "WAIT settle pid=%d sec=%d", pid, settle);
            write_line(STATUS_PATH, msg);
            fprintf(stdout, "%s\n", msg);

            int alive = 1;
            for (int t = 0; t < settle && !g_stop; t++) {
                sleep(1);
                if (find_pid_contains(contains) != pid) {
                    alive = 0;
                    break;
                }
            }
            if (g_stop) break;
            if (!alive) {
                write_line(STATUS_PATH, "FAIL watch game_exited_during_settle");
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
        sleep(3);
    }
    unlink(PIDFILE);
    return 0;
}
