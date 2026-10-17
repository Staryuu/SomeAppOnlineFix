#include "pico_park_2.h"
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <spawn.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <unistd.h>

#ifndef PICO_METADATA_HASH
#define PICO_METADATA_HASH "f6cf4126fcb11a3d6aa57f83927f26c30969794c99050567d3a7f2fe620a8c84"
#define PICO_BINARY_HASH "ff738134f2049bbbc769e89ab94555d2c4c07ac32d58327f1f1b0e8bafc802c2"
#define PICO_AUTH_OFFSET (0x39c8000u + 0x6667d4u)
#endif

static const char old_id[] = "1X/x3gHpVGj8kVdROgk35V/YofQ7JXOXiXzT753mc1DKWnu2nk9rGL5joT0KdWky";
static const char new_id[] = "pdFIvYRhGmBUiGEWWHQc3RnLReb6atz2r0rcjmkqivLFgrSF9T78X/Q/HNq4j3xM";
static const unsigned char steam_auth[] = {0x28, 0x00, 0x80, 0x52}, no_auth[] = {0xe8, 0x1f, 0x80, 0x52};

typedef struct { unsigned char *data; size_t size; mode_t mode; } PicoBlob;
typedef struct {
    char path[PATH_MAX], backup[PATH_MAX], stage[PATH_MAX];
    PicoBlob current, original, patched;
    bool has_backup, changed, active;
} PicoFile;

static int pico_read(const char *path, PicoBlob *blob) {
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return errno;
    struct stat info;
    int result = fstat(fd, &info) < 0 ? errno : 0;
    if (!result && (!S_ISREG(info.st_mode) || info.st_size < 1 || info.st_size > 256 * 1024 * 1024)) result = ENOTSUP;
    if (!result) {
        blob->size = (size_t)info.st_size; blob->mode = info.st_mode;
        blob->data = malloc(blob->size);
        if (!blob->data) result = ENOMEM;
    }
    size_t used = 0;
    while (!result && used < blob->size) {
        ssize_t n = read(fd, blob->data + used, blob->size - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { result = n < 0 ? errno : EIO; break; }
        used += (size_t)n;
    }
    close(fd);
    return result;
}

static bool pico_equal(const PicoBlob *a, const PicoBlob *b) {
    return a->size == b->size && !memcmp(a->data, b->data, a->size);
}

static bool pico_hash(const PicoBlob *blob, const char *expected) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; char hex[65];
    CC_SHA256(blob->data, (CC_LONG)blob->size, digest);
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return !strcmp(hex, expected);
}

static int pico_write(int fd, const PicoBlob *blob) {
    size_t used = 0;
    while (used < blob->size) {
        ssize_t n = write(fd, blob->data + used, blob->size - used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        used += (size_t)n;
    }
    return fsync(fd) == 0 ? 0 : errno;
}

static int pico_stage(PicoFile *file, const PicoBlob *blob) {
    if (*file->stage) unlink(file->stage);
    if (snprintf(file->stage, sizeof(file->stage), "%s.onlinefix-XXXXXX", file->path) >= (int)sizeof(file->stage)) return ENAMETOOLONG;
    int fd = mkstemp(file->stage);
    int result = fd < 0 ? errno : 0;
    if (!result && fchmod(fd, file->current.mode & 0777) < 0) result = errno;
    if (!result) result = pico_write(fd, blob);
    if (fd >= 0 && close(fd) < 0 && !result) result = errno;
    return result;
}

static int pico_replace(PicoFile *file, const PicoBlob *expected) {
    PicoBlob actual = {0};
    int result = pico_read(file->path, &actual);
    if (!result && !pico_equal(&actual, expected)) result = ESTALE;
    if (!result && rename(file->stage, file->path) < 0) result = errno;
    free(actual.data);
    return result;
}

static uint32_t pico_u32(const unsigned char *data) { uint32_t value; memcpy(&value, data, 4); return value; }

static int pico_metadata(PicoFile *file) {
    const PicoBlob *original = &file->original;
    if (original->size < 24 || pico_u32(original->data) != 0xfab11baf || pico_u32(original->data + 4) != 29) return ENOTSUP;
    size_t table = pico_u32(original->data + 8), pool = pico_u32(original->data + 16);
    size_t row = table + 2763 * 8;
    if (row > original->size - 8 || pico_u32(original->data + row) != sizeof(old_id) - 1) return ENOTSUP;
    size_t start = pool + pico_u32(original->data + row + 4);
    if (start > original->size - (sizeof(old_id) - 1) || memcmp(original->data + start, old_id, sizeof(old_id) - 1)) return ENOTSUP;
    memcpy(file->patched.data + start, new_id, sizeof(new_id) - 1);
    return 0;
}

static int pico_codesign(char *const arguments[]) {
    posix_spawn_file_actions_t actions;
    int result = posix_spawn_file_actions_init(&actions);
    if (result) return result;
    result = posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, STDOUT_FILENO, STDERR_FILENO);
    pid_t pid;
    extern char **environ;
    if (!result) result = posix_spawn(&pid, "/usr/bin/codesign", &actions, NULL, arguments, environ);
    posix_spawn_file_actions_destroy(&actions);
    if (result) return result;
    int status;
    while (waitpid(pid, &status, 0) < 0) { if (errno != EINTR) return errno; }
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : EIO;
}

static int pico_binary(PicoFile *file) {
    if (file->original.size < PICO_AUTH_OFFSET + 4 || memcmp(file->original.data + PICO_AUTH_OFFSET, steam_auth, 4)) return ENOTSUP;
    memcpy(file->patched.data + PICO_AUTH_OFFSET, no_auth, 4);
    int result = pico_stage(file, &file->patched);
    char *sign[] = {"codesign", "--force", "--sign", "-", "--identifier", "GameAssembly", "--timestamp=none", file->stage, NULL};
    char *verify[] = {"codesign", "--verify", "--strict", file->stage, NULL};
    if (!result) result = pico_codesign(sign);
    if (!result) result = pico_codesign(verify);
    if (!result) {
        free(file->patched.data); file->patched = (PicoBlob){0};
        result = pico_read(file->stage, &file->patched);
    }
    return result;
}

static int pico_bundle(const char *app) {
    char path[PATH_MAX];
    if (snprintf(path, sizeof(path), "%s/Contents/Info.plist", app) >= (int)sizeof(path)) return ENAMETOOLONG;
    PicoBlob info = {0};
    int result = pico_read(path, &info);
    if (!result) {
        CFDataRef data = CFDataCreate(NULL, info.data, (CFIndex)info.size);
        CFPropertyListRef plist = data ? CFPropertyListCreateWithData(NULL, data, kCFPropertyListImmutable, NULL, NULL) : NULL;
        CFTypeRef identifier = plist && CFGetTypeID(plist) == CFDictionaryGetTypeID()
            ? CFDictionaryGetValue(plist, CFSTR("CFBundleIdentifier")) : NULL;
        if (!identifier || !CFEqual(identifier, CFSTR("com.tecopark.picopark2"))) result = ENOTSUP;
        if (plist) CFRelease(plist);
        if (data) CFRelease(data);
    }
    free(info.data);
    return result;
}

static int pico_apply(const char *app, int mode, bool *enabled) {
    if (!app) return EINVAL;
    char root[PATH_MAX], lock_path[PATH_MAX];
    if (!realpath(app, root)) return errno;
    int result = pico_bundle(root);
    if (result) return result;
    if (snprintf(lock_path, sizeof(lock_path), "%s.onlinefix-endpoint.lock", root) >= (int)sizeof(lock_path)) return ENAMETOOLONG;
    int lock = open(lock_path, O_RDWR | O_CREAT | O_NOFOLLOW, 0600);
    if (lock < 0) return errno;
    if (flock(lock, LOCK_EX | LOCK_NB) < 0) { result = errno; close(lock); return result; }
    PicoFile files[2] = {0};
    const char *relative[] = {"Contents/Resources/Data/il2cpp_data/Metadata/global-metadata.dat", "Contents/Frameworks/GameAssembly.dylib"};
    const char *suffix[] = {".onlinefix-endpoint-backup.dat", ".onlinefix-auth-backup.dylib"};
    const char *hash[] = {PICO_METADATA_HASH, PICO_BINARY_HASH};
    for (size_t i = 0; i < 2 && !result; ++i) {
        PicoFile *file = &files[i];
        if (snprintf(file->path, sizeof(file->path), "%s/%s", root, relative[i]) >= (int)sizeof(file->path) ||
            snprintf(file->backup, sizeof(file->backup), "%s%s", root, suffix[i]) >= (int)sizeof(file->backup)) { result = ENAMETOOLONG; break; }
        result = pico_read(file->path, &file->current);
        if (result) break;
        result = pico_read(file->backup, &file->original);
        file->has_backup = result == 0;
        if (result == ENOENT) { result = 0; file->original = file->current; }
        if (result) break;
        if (!pico_hash(&file->original, hash[i])) { result = file->has_backup ? ESTALE : ENOTSUP; break; }
        file->patched = file->original;
        file->patched.data = malloc(file->original.size);
        if (!file->patched.data) { result = ENOMEM; break; }
        memcpy(file->patched.data, file->original.data, file->original.size);
        result = i == 0 ? pico_metadata(file) : pico_binary(file);
        if (result) break;
        file->active = pico_equal(&file->current, &file->patched);
        if (!file->active && !pico_equal(&file->current, &file->original)) result = ESTALE;
    }
    if (!result && mode < 0) {
        if (files[0].active != files[1].active) result = ESTALE;
        else *enabled = files[0].active;
    }
    for (size_t i = 0; i < 2 && !result && mode >= 0; ++i) {
        PicoFile *file = &files[i];
        const PicoBlob *target = mode ? &file->patched : &file->original;
        result = pico_stage(file, target);
        if (!result && mode && !file->has_backup) {
            int fd = open(file->backup, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (fd < 0) result = errno;
            else {
                result = pico_write(fd, &file->original);
                if (close(fd) < 0 && !result) result = errno;
                if (result) unlink(file->backup);
            }
        }
    }
    for (size_t i = 0; i < 2 && !result && mode >= 0; ++i) {
        PicoFile *file = &files[i];
        if (pico_equal(&file->current, mode ? &file->patched : &file->original)) continue;
        result = pico_replace(file, &file->current);
        file->changed = result == 0;
    }
    if (!result && mode >= 0) {
        for (size_t i = 0; i < 2 && !result; ++i) {
            PicoBlob actual = {0};
            result = pico_read(files[i].path, &actual);
            if (!result && !pico_equal(&actual, mode ? &files[i].patched : &files[i].original)) result = EIO;
            free(actual.data);
        }
    }
    if (result && mode >= 0) {
        for (size_t i = 2; i-- > 0;) {
            if (!files[i].changed) continue;
            int rollback = pico_stage(&files[i], &files[i].current);
            if (!rollback) rollback = pico_replace(&files[i], mode ? &files[i].patched : &files[i].original);
            if (rollback) result = rollback;
        }
    }
    if (!result && mode == 0) {
        for (size_t i = 0; i < 2; ++i) if (unlink(files[i].backup) < 0 && errno != ENOENT && !result) result = errno;
    }
    for (size_t i = 0; i < 2; ++i) {
        if (*files[i].stage) unlink(files[i].stage);
        if (files[i].original.data != files[i].current.data) free(files[i].original.data);
        free(files[i].current.data); free(files[i].patched.data);
    }
    close(lock);
    return result;
}

int of_pico_park_2_patch(const char *app, bool enabled) { return pico_apply(app, enabled, NULL); }
int of_pico_park_2_status(const char *app, bool *enabled) {
    if (!enabled) return EINVAL;
    return pico_apply(app, -1, enabled);
}
