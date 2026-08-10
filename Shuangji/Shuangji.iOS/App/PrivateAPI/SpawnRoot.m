#import "SpawnRoot.h"
#import <spawn.h>
#import <sys/wait.h>
#import <unistd.h>
#import <fcntl.h>
#import <errno.h>
#import <stdlib.h>
#import <string.h>

#define POSIX_SPAWN_PERSONA_FLAGS_OVERRIDE 1
extern int posix_spawnattr_set_persona_np(const posix_spawnattr_t * __restrict, uid_t, uint32_t);
extern int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t * __restrict, uid_t);
extern int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t * __restrict, uid_t);

static int fd_is_valid(int fd) {
    return fcntl(fd, F_GETFD) != -1 || errno != EBADF;
}

static NSString *readPipeLine(int fd) {
    NSMutableString *ms = [NSMutableString new];
    if (!fd_is_valid(fd)) return @"";
    char c;
    ssize_t n;
    while ((n = read(fd, &c, 1)) > 0) {
        [ms appendFormat:@"%c", c];
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

    int status = 0;
    while (waitpid(task_pid, &status, 0) == -1) {
        if (errno != EINTR) {
            if (stdOut) close(out[0]);
            if (stdErr) close(outErr[0]);
            return -222;
        }
    }

    if (stdOut) {
        *stdOut = readPipeLine(out[0]);
        close(out[0]);
    }
    if (stdErr) {
        *stdErr = readPipeLine(outErr[0]);
        close(outErr[0]);
    }

    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return -1;
}
