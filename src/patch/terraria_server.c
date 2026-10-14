#include "terraria_server.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static const char prefix[] = "#!/bin/bash\n";
static const char fix[] =
    "# OnlineFix: Terraria server environment fix\n"
    "unset DYLD_INSERT_LIBRARIES STEAM_DYLD_INSERT_LIBRARIES\n";

static int read_script(const char *path, char **text, struct stat *info) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return errno;
    int result = 0;
    if (fstat(fd, info) < 0) result = errno;
    else if (!S_ISREG(info->st_mode) || info->st_size < 1 || info->st_size > 65536) result = ENOTSUP;
    char *buffer = result ? NULL : malloc((size_t)info->st_size + 1);
    if (!result && !buffer) result = ENOMEM;
    size_t used = 0;
    while (!result && used < (size_t)info->st_size) {
        ssize_t n = read(fd, buffer + used, (size_t)info->st_size - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { result = n < 0 ? errno : EIO; break; }
        used += (size_t)n;
    }
    close(fd);
    if (!result) {
        buffer[used] = '\0';
        if (memchr(buffer, '\0', used)) result = ENOTSUP;
    }
    if (result) free(buffer);
    else *text = buffer;
    return result;
}

static int write_all(int fd, const char *text) {
    size_t remaining = strlen(text);
    while (remaining) {
        ssize_t n = write(fd, text, remaining);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        text += n; remaining -= (size_t)n;
    }
    return fsync(fd) == 0 ? 0 : errno;
}

static bool supported(const char *text) {
    return !strncmp(text, prefix, sizeof(prefix) - 1) &&
        strstr(text, "# MonoKickstart Shell Script") && strstr(text, "./TerrariaServer.bin.osx") &&
        !strstr(text, "# OnlineFix: Terraria server environment fix");
}

static int replace_script(const char *path, const char *expected, const char *replacement, mode_t mode) {
    char *temporary = NULL;
    if (asprintf(&temporary, "%s.onlinefix-XXXXXX", path) < 0) return ENOMEM;
    int fd = mkstemp(temporary);
    int result = fd < 0 ? errno : 0;
    if (!result && fchmod(fd, mode & 0777) < 0) result = errno;
    if (!result) result = write_all(fd, replacement);
    if (fd >= 0 && close(fd) < 0 && !result) result = errno;
    char *current = NULL;
    struct stat info;
    if (!result) result = read_script(path, &current, &info);
    if (!result && strcmp(current, expected)) result = ESTALE;
    if (!result && rename(temporary, path) < 0) result = errno;
    free(current);
    unlink(temporary);
    free(temporary);
    return result;
}

int of_terraria_server_patch(const char *launcher, bool enabled) {
    if (!launcher) return EINVAL;
    const char *base = strrchr(launcher, '/');
    if (strcmp(base ? base + 1 : launcher, "TerrariaServer")) return ENOTSUP;
    char *current = NULL, *original = NULL, *patched = NULL, *backup = NULL;
    struct stat info, backup_info;
    int result = read_script(launcher, &current, &info);
    if (result) return result;
    if (asprintf(&backup, "%s.onlinefix-backup", launcher) < 0) { free(current); return ENOMEM; }
    int backup_result = read_script(backup, &original, &backup_info);
    if (backup_result != 0 && backup_result != ENOENT) { result = backup_result; goto done; }
    if (backup_result == ENOENT) {
        if (!enabled) {
            result = strstr(current, fix) ? ESTALE : 0;
            goto done;
        }
        if (!supported(current)) { result = ENOTSUP; goto done; }
        original = strdup(current);
        if (!original) { result = ENOMEM; goto done; }
    }
    if (!supported(original)) { result = ESTALE; goto done; }
    if (strlen(original) + strlen(fix) > 65536) { result = EFBIG; goto done; }
    if (asprintf(&patched, "%s%s%s", prefix, fix, original + sizeof(prefix) - 1) < 0) {
        result = ENOMEM; goto done;
    }
    if (strcmp(current, original) && strcmp(current, patched)) { result = ESTALE; goto done; }
    if (enabled) {
        if (backup_result == ENOENT) {
            int fd = open(backup, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (fd < 0) { result = errno; goto done; }
            result = write_all(fd, original);
            if (close(fd) < 0 && !result) result = errno;
            if (result) { unlink(backup); goto done; }
        }
        if (strcmp(current, patched)) result = replace_script(launcher, current, patched, info.st_mode);
    } else {
        if (strcmp(current, original)) result = replace_script(launcher, current, original, info.st_mode);
        if (!result && unlink(backup) < 0) result = errno;
    }
done:
    free(current); free(original); free(patched); free(backup);
    return result;
}
