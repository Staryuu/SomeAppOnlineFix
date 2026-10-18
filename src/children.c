#include "onlinefix.h"
#include <dobby.h>
#include <crt_externs.h>
#include <errno.h>
#include <mach-o/dyld.h>
#include <spawn.h>
#include <stdlib.h>
#include <string.h>

static int (*real_execve)(const char *, char *const [], char *const []);
static int (*real_execv)(const char *, char *const []);
static int (*real_spawn)(pid_t *, const char *, const posix_spawn_file_actions_t *,
                         const posix_spawnattr_t *, char *const [], char *const []);

static bool child_filter_owner(const char *path) {
    if (!path) return false;
    const char *base = strrchr(path, '/');
    base = base ? base + 1 : path;
    return !strcmp(base, "macsteam.dylib") || !strcmp(base, "notproton.dylib");
}

static bool steam_target(const char *path) {
    if (!path) return false;
    const char *base = strrchr(path, '/');
    return !strcmp(base ? base + 1 : path, "steam_osx");
}

static char **child_environment(char *const env[]) {
    size_t count = 0;
    char *const *source = env ? env : *_NSGetEnviron();
    while (source[count]) ++count;
    char **copy = calloc(count + 1, sizeof(*copy));
    if (!copy) return NULL;
    size_t written = 0;
    for (size_t i = 0; i < count; ++i) {
        // Helpers must not inherit the injected library.
        if (strncmp(source[i], "DYLD_INSERT_LIBRARIES=", sizeof("DYLD_INSERT_LIBRARIES=") - 1))
            copy[written++] = source[i];
    }
    return copy;
}

static int execute(const char *path, char *const args[], char *const env[]) {
    if (steam_target(path)) return real_execve(path, args, env);
    char **filtered = child_environment(env);
    if (!filtered) { errno = ENOMEM; return -1; }
    int result = real_execve(path, args, filtered);
    int error = errno;
    free(filtered);
    errno = error;
    return result;
}

static int execute_inherited(const char *path, char *const args[]) {
    return real_execve ? execute(path, args, *_NSGetEnviron()) : real_execv(path, args);
}

static int spawn_child(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                       const posix_spawnattr_t *attributes, char *const args[], char *const env[]) {
    if (steam_target(path)) return real_spawn(pid, path, actions, attributes, args, env);
    char **filtered = child_environment(env);
    if (!filtered) return ENOMEM;
    int result = real_spawn(pid, path, actions, attributes, args, filtered);
    free(filtered);
    return result;
}

void of_filter_children(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *image = _dyld_get_image_name(i);
        if (child_filter_owner(image)) {
            // NotProton also restores its insert for Steam Helper; a second filter would strip it.
            of_log("child environment filtering handled by %s", image);
            return;
        }
    }
    struct { const char *name; void *handler; void **original; } hooks[] = {
        {"execve", (void *)execute, (void **)&real_execve},
        {"execv", (void *)execute_inherited, (void **)&real_execv},
        {"posix_spawn", (void *)spawn_child, (void **)&real_spawn},
    };
    for (size_t i = 0; i < sizeof(hooks) / sizeof(hooks[0]); ++i) {
        void *address = DobbySymbolResolver(NULL, hooks[i].name);
        if (!address || DobbyHook(address, hooks[i].handler, hooks[i].original))
            of_log("child environment filtering unavailable for %s", hooks[i].name);
    }
}
