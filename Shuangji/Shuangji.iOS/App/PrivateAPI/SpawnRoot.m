#import "SpawnRoot.h"
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>
#import <poll.h>
#import <signal.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

static int fd_is_valid(int fd) {
    return fcntl(fd, F_GETFD) != -1 || errno != EBADF;
}

static NSString *readPipeLimited(int fd, int timeoutMs) {
    NSMutableString *ms = [NSMutableString new];
    if (!fd_is_valid(fd)) return @"";
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    char buf[1024];
    int waited = 0;
    while (waited < timeoutMs) {
        struct pollfd pfd = { .fd = fd, .events = POLLIN };
        int pr = poll(&pfd, 1, 50);
        if (pr > 0 && (pfd.revents & POLLIN)) {
            ssize_t n = read(fd, buf, sizeof(buf));
            if (n > 0) {
                [ms appendFormat:@"%.*s", (int)n, buf];
                continue;
            }
            if (n == 0) break; // EOF
            if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                waited += 50;
                continue;
            }
            break;
        }
        if (pr == 0) {
            waited += 50;
            continue;
        }
        break;
    }
    return ms.copy;
}

int SYSpawnRoot(NSString *path, NSArray<NSString *> *args, NSString **stdOut, NSString **stdErr) {
    NSMutableArray *argsM = args.mutableCopy ?: [NSMutableArray new];
    [argsM insertObject:path.lastPathComponent atIndex:0];

    NSUInteger argCount = argsM.count;
    char **argsC = (char **)calloc(argCount + 1, sizeof(char *));
    if (!argsC) return -1;
    for (NSUInteger i = 0; i < argCount; i++) {
        argsC[i] = strdup([argsM[i] UTF8String]);
    }
    argsC[argCount] = NULL;

    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_set_persona_np(&attr, 99, POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE);
    posix_spawnattr_set_persona_uid_np(&attr, 0);
    posix_spawnattr_set_persona_gid_np(&attr, 0);

    posix_spawn_file_actions_t action;
    posix_spawn_file_actions_init(&action);

    int outErr[2] = {-1, -1};
    int out[2] = {-1, -1};
    if (stdErr) {
        pipe(outErr);
        posix_spawn_file_actions_adddup2(&action, outErr[1], STDERR_FILENO);
        posix_spawn_file_actions_addclose(&action, outErr[0]);
    }
    if (stdOut) {
        pipe(out);
        posix_spawn_file_actions_adddup2(&action, out[1], STDOUT_FILENO);
        posix_spawn_file_actions_addclose(&action, out[0]);
    }

    pid_t task_pid = 0;
    int spawnError = posix_spawn(&task_pid, path.fileSystemRepresentation, &action, &attr, (char *const *)argsC, NULL);
    posix_spawnattr_destroy(&attr);
    posix_spawn_file_actions_destroy(&action);

    for (NSUInteger i = 0; i < argCount; i++) free(argsC[i]);
    free(argsC);

    if (stdOut) close(out[1]);
    if (stdErr) close(outErr[1]);

    if (spawnError != 0) {
        if (stdOut) close(out[0]);
        if (stdErr) close(outErr[0]);
        return -spawnError;
    }

    /* 最多等 8 秒，超时强杀，避免部署卡死 */
    const int timeoutSec = 8;
    int status = 0;
    int elapsed = 0;
    int done = 0;
    while (elapsed < timeoutSec * 10) {
        pid_t w = waitpid(task_pid, &status, WNOHANG);
        if (w == task_pid) { done = 1; break; }
        if (w < 0 && errno != EINTR) {
            if (stdOut) close(out[0]);
            if (stdErr) close(outErr[0]);
            return -222;
        }
        usleep(100000); /* 100ms */
        elapsed++;
    }
    if (!done) {
        kill(task_pid, SIGKILL);
        waitpid(task_pid, &status, 0);
        if (stdOut) {
            *stdOut = readPipeLimited(out[0], 200);
            close(out[0]);
        }
        if (stdErr) {
            *stdErr = [NSString stringWithFormat:@"TIMEOUT %ds %@", timeoutSec,
                       readPipeLimited(outErr[0], 200)];
            close(outErr[0]);
        }
        return -999;
    }

    if (stdOut) {
        *stdOut = readPipeLimited(out[0], 500);
        close(out[0]);
    }
    if (stdErr) {
        *stdErr = readPipeLimited(outErr[0], 500);
        close(outErr[0]);
    }

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
