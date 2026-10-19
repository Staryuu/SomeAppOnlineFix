#include "repo.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef REPO_HASH
// Build 23363152. DataDirector overwrites the App IDs stored in the assets.
#define REPO_HASH "ce995a182ddc884ea965e87786f1986248d9616300fa825bcc04bca671ee6526"
#define REPO_SIZE 2963968u
#define REPO_PUN_OFFSET 0x2a2ca0u
#define REPO_VOICE_OFFSET 0x2a2ceau
#define REPO_AUTH_OFFSET 0x156b48u
#endif

static const char *const repo_original_ids[] = {"99515094-45b7-4c98-ab70-a448c548c83d", "dfc40a01-c3a4-4395-9707-b71118816d2b"};
static const size_t repo_offsets[] = {REPO_PUN_OFFSET, REPO_VOICE_OFFSET, REPO_AUTH_OFFSET};
static const size_t repo_lengths[] = {72, 72, 40};
static const unsigned char repo_auth[] = {
    0x28, 0xf8, 0x0b, 0x00, 0x0a, 0x17, 0x6f, 0xfa, 0x0b, 0x00, 0x0a, 0x02, 0x02, 0x7c,
    0x82, 0x37, 0x00, 0x04, 0x28, 0xf9, 0x1f, 0x00, 0x06, 0x0a, 0x28, 0xf8, 0x0b, 0x00,
    0x0a, 0x72, 0x0f, 0x84, 0x01, 0x70, 0x06, 0x6f, 0xfb, 0x0b, 0x00, 0x0a
};
// Keep the Steam UserId, then return before setting Steam authentication.
static const unsigned char repo_no_auth[40] = {0x2a};

static bool repo_guid(const char *s) {
    if (!s || strlen(s) != 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (s[i] != '-') return false; }
        else if (!((s[i] >= '0' && s[i] <= '9') || (s[i] >= 'a' && s[i] <= 'f') || (s[i] >= 'A' && s[i] <= 'F'))) return false;
    }
    return strcasecmp(s, repo_original_ids[0]) && strcasecmp(s, repo_original_ids[1]);
}

bool of_repo_validate_ids(const char *pun, const char *voice) {
    return repo_guid(pun) && voice && (!*voice || (repo_guid(voice) && strcasecmp(pun, voice)));
}

static void repo_encode(unsigned char *out, const char *id) {
    for (size_t i = 0; i < 36; ++i) {
        out[2 * i] = id[i] >= 'A' && id[i] <= 'F' ? (unsigned char)(id[i] + 'a' - 'A') : (unsigned char)id[i];
        out[2 * i + 1] = 0;
    }
}

static int repo_read(int fd, unsigned char *data) {
    struct stat info;
    if (fstat(fd, &info) < 0) return errno;
    if (!S_ISREG(info.st_mode) || info.st_nlink != 1 || info.st_size != REPO_SIZE) return ENOTSUP;
    for (size_t used = 0; used < REPO_SIZE;) {
        ssize_t n = pread(fd, data + used, REPO_SIZE - used, (off_t)used);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        used += (size_t)n;
    }
    return 0;
}

static int repo_write(int fd, const unsigned char *data, size_t length, off_t offset) {
    while (length) {
        ssize_t n = pwrite(fd, data, length, offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        data += n; length -= (size_t)n; offset += n;
    }
    return fsync(fd) < 0 ? errno : 0;
}

static bool repo_hash(const unsigned char *data) {
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; char hex[65];
    CC_SHA256(data, REPO_SIZE, digest);
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hex + 2 * i, 3, "%02x", digest[i]);
    return !strcmp(hex, REPO_HASH);
}

static int repo_inspect(const unsigned char *data, unsigned char *original, char pun[37], char voice[37]) {
    memcpy(original, data, REPO_SIZE);
    char ids[2][37] = {{0}};
    for (size_t i = 0; i < 2; ++i) {
        for (size_t j = 0; j < 36; ++j) {
            if (data[repo_offsets[i] + 2 * j + 1]) return ENOTSUP;
            ids[i][j] = (char)data[repo_offsets[i] + 2 * j];
        }
        repo_encode(original + repo_offsets[i], repo_original_ids[i]);
    }
    memcpy(original + REPO_AUTH_OFFSET, repo_auth, sizeof(repo_auth));
    if (!repo_hash(original)) return ENOTSUP;
    bool clean = !memcmp(data, original, REPO_SIZE);
    if (clean) { pun[0] = voice[0] = 0; return 0; }
    if (!strcmp(ids[1], repo_original_ids[1])) ids[1][0] = 0;
    if (!of_repo_validate_ids(ids[0], ids[1]) || memcmp(data + REPO_AUTH_OFFSET, repo_no_auth, sizeof(repo_no_auth))) return ESTALE;
    memcpy(pun, ids[0], 37); memcpy(voice, ids[1], 37);
    return 0;
}

static int repo_apply(const char *directory, const char *pun, const char *voice, int mode, char *status_pun, char *status_voice) {
    if (!directory || (mode == 1 && !of_repo_validate_ids(pun, voice))) return EINVAL;
    int root = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (root < 0) return errno;
    int result = flock(root, LOCK_EX | LOCK_NB) < 0 ? errno : 0;
    int data_dir = -1, managed = -1, fd = -1, parent = -1, backup = -1;
    unsigned char *current = NULL, *original = NULL, *next = NULL, *actual = NULL;
    char path[PATH_MAX], name[NAME_MAX + 1], current_pun[37] = {0}, current_voice[37] = {0};
    struct stat before;
    if (!result) { data_dir = openat(root, "REPO_Data", O_RDONLY | O_DIRECTORY | O_NOFOLLOW); if (data_dir < 0) result = errno; }
    if (!result) { managed = openat(data_dir, "Managed", O_RDONLY | O_DIRECTORY | O_NOFOLLOW); if (managed < 0) result = errno; }
    if (!result) { fd = openat(managed, "Assembly-CSharp.dll", (mode < 0 ? O_RDONLY : O_RDWR) | O_NOFOLLOW); if (fd < 0) result = errno; }
    if (!result && fstat(fd, &before) < 0) result = errno;
    if (!result) {
        current = malloc(REPO_SIZE); original = malloc(REPO_SIZE); next = malloc(REPO_SIZE); actual = malloc(REPO_SIZE);
        if (!current || !original || !next || !actual) result = ENOMEM;
    }
    if (!result) result = repo_read(fd, current);
    if (!result) result = repo_inspect(current, original, current_pun, current_voice);
    if (!result && fcntl(root, F_GETPATH, path) < 0) result = errno;
    if (!result) {
        const char *base = strrchr(path, '/');
        if (!base || !base[1]) result = ENOTSUP;
        else if (snprintf(name, sizeof(name), "%s.onlinefix-repo-Assembly-CSharp.dll.backup", base + 1) >= (int)sizeof(name)) result = ENAMETOOLONG;
    }
    if (!result) { parent = openat(root, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW); if (parent < 0) result = errno; }
    if (!result) {
        backup = openat(parent, name, O_RDONLY | O_NOFOLLOW);
        if (backup < 0 && errno != ENOENT) result = errno;
        if (!result && backup >= 0) {
            result = repo_read(backup, actual);
            if (!result && memcmp(actual, original, REPO_SIZE)) result = ESTALE;
            if (result == ENOTSUP) result = ESTALE;
        } else if (!result && *current_pun) result = ESTALE;
    }
    if (!result && mode < 0) { memcpy(status_pun, current_pun, 37); memcpy(status_voice, current_voice, 37); }
    if (!result && mode >= 0) {
        memcpy(next, original, REPO_SIZE);
        if (mode) {
            repo_encode(next + REPO_PUN_OFFSET, pun);
            if (*voice) repo_encode(next + REPO_VOICE_OFFSET, voice);
            memcpy(next + REPO_AUTH_OFFSET, repo_no_auth, sizeof(repo_no_auth));
        }
        if (mode && backup < 0) {
            backup = openat(parent, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
            if (backup < 0) result = errno;
            else {
                result = repo_write(backup, original, REPO_SIZE, 0);
                if (!result) result = repo_read(backup, actual);
                if (!result && memcmp(actual, original, REPO_SIZE)) result = EIO;
                if (!result && fsync(parent) < 0) result = errno;
                if (result) unlinkat(parent, name, 0);
            }
        }
        struct stat info;
        if (!result && fstatat(managed, "Assembly-CSharp.dll", &info, AT_SYMLINK_NOFOLLOW) < 0) result = errno;
        if (!result && (info.st_dev != before.st_dev || info.st_ino != before.st_ino || info.st_size != before.st_size ||
            info.st_mtimespec.tv_sec != before.st_mtimespec.tv_sec || info.st_mtimespec.tv_nsec != before.st_mtimespec.tv_nsec ||
            info.st_ctimespec.tv_sec != before.st_ctimespec.tv_sec || info.st_ctimespec.tv_nsec != before.st_ctimespec.tv_nsec)) result = ESTALE;
        if (!result) result = repo_read(fd, actual);
        if (!result && memcmp(actual, current, REPO_SIZE)) result = ESTALE;
        bool changed = false;
        for (size_t i = 0; i < 3 && !result; ++i) {
            if (!memcmp(current + repo_offsets[i], next + repo_offsets[i], repo_lengths[i])) continue;
            changed = true;
            result = repo_write(fd, next + repo_offsets[i], repo_lengths[i], (off_t)repo_offsets[i]);
        }
        if (!result) result = repo_read(fd, actual);
        if (!result && memcmp(actual, next, REPO_SIZE)) result = EIO;
        if (result && changed) {
            for (size_t i = 3; i-- > 0;) {
                int rollback = repo_write(fd, current + repo_offsets[i], repo_lengths[i], (off_t)repo_offsets[i]);
                if (rollback) result = rollback;
            }
        }
        if (!result && !mode && backup >= 0) {
            if (unlinkat(parent, name, 0) < 0 || fsync(parent) < 0) result = errno;
        }
    }
    free(current); free(original); free(next); free(actual);
    if (backup >= 0) close(backup);
    if (parent >= 0) close(parent);
    if (fd >= 0) close(fd);
    if (managed >= 0) close(managed);
    if (data_dir >= 0) close(data_dir);
    close(root);
    return result;
}

int of_repo_patch(const char *directory, const char *pun, const char *voice, bool enabled) {
    return repo_apply(directory, pun, voice, enabled ? 1 : 0, NULL, NULL);
}

int of_repo_status(const char *directory, char pun[37], char voice[37]) {
    if (!pun || !voice) return EINVAL;
    pun[0] = voice[0] = 0;
    return repo_apply(directory, NULL, NULL, -1, pun, voice);
}
