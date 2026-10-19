#include "phasmophobia.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/clonefile.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

#ifndef PHASM_BINARY_HASH
#define PHASM_BINARY_HASH "e300eda993f2479922628f1b44f59e60c156c240f5a07c7289c4bd0fe4b790c8"
#define PHASM_RESOURCE_HASH "a4263756baf02fe2cf40e1aa5a1c8b74ab487432ddc7bc3e719ed48d158334f5"
#define PHASM_METADATA_HASH "a1d282afc5a7dada6617f30f0b8a595a8bc5ce32f27cd81baf38903711c68253"
#define PHASM_AUTH_RVA 0xee7423u
#define PHASM_RESOURCE_OFFSET 0x41f17600u
#endif

static const unsigned char ph_auth[] = {0xc6, 0x47, 0x10, 0x01};
static const char ph_appid[] = "80449c66-0a91-49a5-acb6-ca805e84e605";
typedef struct {
    int fd, parent, backup, backup_parent;
    const char *name, *hash;
    char backup_name[NAME_MAX + 1];
    char legacy_name[NAME_MAX + 1];
    struct stat info;
    off_t offset;
    size_t length;
    unsigned char original[36], current[36], target[36];
    bool changed, legacy_backup;
} PhasmFile;

static bool ph_guid(const char *value) {
    if (!value || strlen(value) != 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) { if (value[i] != '-') return false; }
        else if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f') ||
                   (value[i] >= 'A' && value[i] <= 'F'))) return false;
    }
    return true;
}

static int ph_read(int fd, void *data, size_t length, off_t offset) {
    unsigned char *out = data;
    while (length) {
        ssize_t n = pread(fd, out, length, offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        out += n; offset += n; length -= (size_t)n;
    }
    return 0;
}

static int ph_write(int fd, const void *data, size_t length, off_t offset) {
    const unsigned char *in = data;
    while (length) {
        ssize_t n = pwrite(fd, in, length, offset);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n < 0 ? errno : EIO;
        in += n; offset += n; length -= (size_t)n;
    }
    return fsync(fd) < 0 ? errno : 0;
}

static int ph_regular(int fd, struct stat *info) {
    if (fstat(fd, info) < 0) return errno;
    return S_ISREG(info->st_mode) && info->st_size > 0 && info->st_nlink == 1 ? 0 : ENOTSUP;
}

// Hash the original patch bytes so clean and patched files can be compared.
static int ph_hash(int fd, const char *expected, const PhasmFile *patch) {
    struct stat info;
    int result = ph_regular(fd, &info);
    CC_SHA256_CTX context;
    CC_SHA256_Init(&context);
    unsigned char buffer[65536], digest[CC_SHA256_DIGEST_LENGTH]; char hex[65];
    for (off_t offset = 0; !result && offset < info.st_size;) {
        size_t length = (size_t)(info.st_size - offset);
        if (length > sizeof(buffer)) length = sizeof(buffer);
        result = ph_read(fd, buffer, length, offset);
        if (result) break;
        if (patch) {
            for (size_t i = 0; i < patch->length; ++i) {
                off_t at = patch->offset + (off_t)i;
                if (at >= offset && at < offset + (off_t)length) buffer[at - offset] = patch->original[i];
            }
        }
        CC_SHA256_Update(&context, buffer, (CC_LONG)length);
        offset += (off_t)length;
    }
    if (result) return result;
    CC_SHA256_Final(digest, &context);
    for (size_t i = 0; i < sizeof(digest); ++i) snprintf(hex + i * 2, 3, "%02x", digest[i]);
    return strcmp(hex, expected) ? ENOTSUP : 0;
}

static uint32_t ph_u32(const unsigned char *data) { uint32_t value; memcpy(&value, data, 4); return value; }
static uint16_t ph_u16(const unsigned char *data) { uint16_t value; memcpy(&value, data, 2); return value; }

static int ph_auth_offset(PhasmFile *file) {
    unsigned char dos[64] = {0}, header[24], optional[64], section[40];
    int result = ph_read(file->fd, dos, sizeof(dos), 0);
    uint32_t pe = ph_u32(dos + 60);
    if (result || memcmp(dos, "MZ", 2) || pe > file->info.st_size - 24) return ENOTSUP;
    result = ph_read(file->fd, header, sizeof(header), pe);
    if (result || memcmp(header, "PE\0\0", 4) || ph_u16(header + 4) != 0x8664) return ENOTSUP;
    uint16_t count = ph_u16(header + 6), size = ph_u16(header + 20);
    if (!count || count > 96 || size < sizeof(optional)) return ENOTSUP;
    result = ph_read(file->fd, optional, sizeof(optional), (off_t)pe + 24);
    if (result || ph_u16(optional) != 0x20b) return ENOTSUP;
    off_t table = (off_t)pe + 24 + size;
    if (table > file->info.st_size - (off_t)count * 40) return ENOTSUP;
    for (uint16_t i = 0; i < count; ++i) {
        if (ph_read(file->fd, section, sizeof(section), table + i * 40)) return ENOTSUP;
        uint32_t rva = ph_u32(section + 12), raw_size = ph_u32(section + 16), raw = ph_u32(section + 20);
        if (PHASM_AUTH_RVA < rva || (uint64_t)PHASM_AUTH_RVA + sizeof(ph_auth) > (uint64_t)rva + raw_size) continue;
        if (!(ph_u32(section + 36) & 0x20000000)) return ENOTSUP;
        file->offset = (off_t)raw + PHASM_AUTH_RVA - rva;
        return file->offset <= file->info.st_size - (off_t)sizeof(ph_auth) ? 0 : ENOTSUP;
    }
    return ENOTSUP;
}

static int ph_parent(int root, const char *relative) {
    char path[PATH_MAX];
    if (strlen(relative) >= sizeof(path)) { errno = ENAMETOOLONG; return -1; }
    strcpy(path, relative);
    int directory = dup(root);
    char *save = NULL;
    for (char *part = strtok_r(path, "/", &save); part && directory >= 0; part = strtok_r(NULL, "/", &save)) {
        int next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        int error = errno; close(directory); directory = next; errno = error;
    }
    return directory;
}

static int ph_inspect(PhasmFile *file, bool binary) {
    int result = ph_regular(file->fd, &file->info);
    if (!result && binary) result = ph_auth_offset(file);
    if (!result && !binary) {
        unsigned char length[4];
        result = ph_read(file->fd, length, 4, file->offset - 4);
        if (!result && ph_u32(length) != 36) result = ENOTSUP;
    }
    if (!result) result = ph_read(file->fd, file->current, file->length, file->offset);
    if (result) return result;
    if (binary) {
        if (memcmp(file->current, ph_auth, 3) || (file->current[3] != 1 && file->current[3] != 0xff)) return ENOTSUP;
    } else {
        char id[37]; memcpy(id, file->current, 36); id[36] = 0;
        if (!ph_guid(id)) return ENOTSUP;
    }
    file->backup = openat(file->backup_parent, file->backup_name, O_RDONLY | O_NOFOLLOW);
    if (file->backup < 0 && errno != ENOENT) return errno;
    int legacy = openat(file->parent, file->legacy_name, O_RDONLY | O_NOFOLLOW);
    if (legacy < 0 && errno != ENOENT) return errno;
    if (legacy >= 0) {
        if (file->backup >= 0) { close(legacy); return ESTALE; }
        file->backup = legacy;
        file->legacy_backup = true;
    }
    result = ph_hash(file->fd, file->hash, file);
    if (result) return result == ENOTSUP && file->backup >= 0 ? ESTALE : result;
    if (file->backup >= 0) {
        result = ph_hash(file->backup, file->hash, NULL);
        if (result == ENOTSUP) result = ESTALE;
    } else if (memcmp(file->current, file->original, file->length)) result = ESTALE;
    return result;
}

static int ph_backup(PhasmFile *file) {
    if (file->legacy_backup) {
        if (renameatx_np(file->parent, file->legacy_name, file->backup_parent, file->backup_name, RENAME_EXCL) < 0) return errno;
        file->legacy_backup = false;
        if (fsync(file->backup_parent) < 0 || fsync(file->parent) < 0) return errno;
    }
    if (file->backup >= 0) return 0;
    int result = 0;
    if (fclonefileat(file->fd, file->backup_parent, file->backup_name, 0) < 0) {
        if (errno != ENOTSUP && errno != EXDEV && errno != EINVAL) return errno;
        int fd = openat(file->backup_parent, file->backup_name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
        if (fd < 0) return errno;
        unsigned char buffer[65536];
        for (off_t offset = 0; !result && offset < file->info.st_size;) {
            size_t length = (size_t)(file->info.st_size - offset);
            if (length > sizeof(buffer)) length = sizeof(buffer);
            result = ph_read(file->fd, buffer, length, offset);
            if (!result) {
                size_t used = 0;
                while (!result && used < length) {
                    ssize_t n = write(fd, buffer + used, length - used);
                    if (n < 0 && errno == EINTR) continue;
                    if (n <= 0) result = n < 0 ? errno : EIO;
                    else used += (size_t)n;
                }
            }
            offset += (off_t)length;
        }
        if (!result && fsync(fd) < 0) result = errno;
        if (close(fd) < 0 && !result) result = errno;
    }
    if (!result) {
        file->backup = openat(file->backup_parent, file->backup_name, O_RDONLY | O_NOFOLLOW);
        if (file->backup < 0) result = errno;
        else {
            result = ph_hash(file->backup, file->hash, NULL);
            if (!result && fsync(file->backup) < 0) result = errno;
        }
    }
    if (result) unlinkat(file->backup_parent, file->backup_name, 0);
    else if (fsync(file->backup_parent) < 0) result = errno;
    return result;
}

static int ph_unchanged(PhasmFile *file) {
    struct stat actual;
    if (fstatat(file->parent, file->name, &actual, AT_SYMLINK_NOFOLLOW) < 0) return errno;
    if (actual.st_dev != file->info.st_dev || actual.st_ino != file->info.st_ino || actual.st_size != file->info.st_size ||
        actual.st_mtimespec.tv_sec != file->info.st_mtimespec.tv_sec || actual.st_mtimespec.tv_nsec != file->info.st_mtimespec.tv_nsec ||
        actual.st_ctimespec.tv_sec != file->info.st_ctimespec.tv_sec || actual.st_ctimespec.tv_nsec != file->info.st_ctimespec.tv_nsec) return ESTALE;
    return 0;
}

static int ph_apply(const char *game_directory, const char *photon_app_id, int mode, char *status_id) {
    bool enabled = mode == 1;
    if (!game_directory || (enabled && (!ph_guid(photon_app_id) || !strcasecmp(photon_app_id, ph_appid)))) return EINVAL;
    int root = open(game_directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
    if (root < 0) return errno;
    // Lock the folder. A new lock file would trigger the game's startup checks.
    int result = flock(root, LOCK_EX | LOCK_NB) < 0 ? errno : 0;
    int backup_parent = -1;
    char root_path[PATH_MAX] = {0};
    if (!result && fcntl(root, F_GETPATH, root_path) < 0) result = errno;
    const char *root_name = strrchr(root_path, '/');
    if (!result && (!root_name || !root_name[1])) result = ENOTSUP;
    if (!result) {
        backup_parent = openat(root, "..", O_RDONLY | O_DIRECTORY | O_NOFOLLOW);
        if (backup_parent < 0) result = errno;
    }
    // Respect existing legacy locks without creating new ones.
    int lock = !result ? openat(root, ".onlinefix-phasmophobia.lock", O_RDWR | O_NOFOLLOW) : -1;
    if (!result && lock < 0 && errno != ENOENT) result = errno;
    struct stat lock_info;
    if (!result && lock >= 0 && fstat(lock, &lock_info) < 0) result = errno;
    if (!result && lock >= 0 && (!S_ISREG(lock_info.st_mode) || lock_info.st_nlink != 1 || lock_info.st_size != 0)) result = ENOTSUP;
    if (!result && lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) < 0) result = errno;
    PhasmFile files[2] = {{.fd = -1, .parent = -1, .backup = -1}, {.fd = -1, .parent = -1, .backup = -1}};
    const char *parents[] = {"", "Phasmophobia_Data"};
    const char *names[] = {"GameAssembly.dll", "resources.assets"};
    const char *hashes[] = {PHASM_BINARY_HASH, PHASM_RESOURCE_HASH};
    int metadata_parent = -1, metadata = -1;
    if (!result) {
        metadata_parent = ph_parent(root, "Phasmophobia_Data/il2cpp_data/Metadata");
        if (metadata_parent < 0) result = errno;
        else metadata = openat(metadata_parent, "global-metadata.dat", O_RDONLY | O_NOFOLLOW);
        if (!result) result = metadata < 0 ? errno : ph_hash(metadata, PHASM_METADATA_HASH, NULL);
    }
    for (size_t i = 0; i < 2 && !result; ++i) {
        PhasmFile *file = &files[i];
        file->parent = ph_parent(root, parents[i]); file->name = names[i]; file->hash = hashes[i];
        if (file->parent < 0) { result = errno; break; }
        file->backup_parent = backup_parent;
        snprintf(file->legacy_name, sizeof(file->legacy_name), "%s.onlinefix-phasmophobia-backup", file->name);
        if (snprintf(file->backup_name, sizeof(file->backup_name), "%s.onlinefix-phasmophobia-%s.backup", root_name + 1, file->name) >= (int)sizeof(file->backup_name)) { result = ENAMETOOLONG; break; }
        file->fd = openat(file->parent, file->name, (mode < 0 ? O_RDONLY : O_RDWR) | O_NOFOLLOW);
        if (file->fd < 0) { result = errno; break; }
        file->length = i ? 36 : sizeof(ph_auth); file->offset = i ? PHASM_RESOURCE_OFFSET : 0;
        memcpy(file->original, i ? (const void *)ph_appid : (const void *)ph_auth, file->length);
        memcpy(file->target, file->original, file->length);
        if (enabled) {
            if (i) memcpy(file->target, photon_app_id, 36);
            else file->target[3] = 0xff;
        }
        result = ph_inspect(file, i == 0);
    }
    if (!result && mode < 0) {
        bool auth = files[0].current[3] == 0xff;
        bool appid = memcmp(files[1].current, files[1].original, 36) != 0;
        if (auth != appid) result = ESTALE;
        else if (auth) { memcpy(status_id, files[1].current, 36); status_id[36] = 0; }
        else status_id[0] = 0;
    }
    for (size_t i = 0; i < 2 && !result && enabled; ++i) result = ph_backup(&files[i]);
    for (size_t i = 0; i < 2 && !result; ++i) result = ph_unchanged(&files[i]);
    for (size_t i = 0; i < 2 && !result && mode >= 0; ++i) {
        PhasmFile *file = &files[i];
        if (!memcmp(file->current, file->target, file->length)) continue;
        file->changed = true;
        result = ph_write(file->fd, file->target, file->length, file->offset);
    }
    for (size_t i = 0; i < 2 && !result && mode >= 0; ++i) {
        unsigned char actual[36]; PhasmFile *file = &files[i];
        result = ph_read(file->fd, actual, file->length, file->offset);
        if (!result && memcmp(actual, file->target, file->length)) result = EIO;
        if (!result) result = ph_hash(file->fd, file->hash, file);
    }
    if (result) {
        for (size_t i = 2; i-- > 0;) if (files[i].changed) {
            int rollback = ph_write(files[i].fd, files[i].current, files[i].length, files[i].offset);
            if (rollback) result = rollback;
        }
    } else if (mode == 0) {
        for (size_t i = 0; i < 2 && !result; ++i) if (files[i].backup >= 0) {
            PhasmFile *file = &files[i];
            int parent = file->legacy_backup ? file->parent : file->backup_parent;
            const char *name = file->legacy_backup ? file->legacy_name : file->backup_name;
            if (unlinkat(parent, name, 0) < 0 || fsync(parent) < 0) result = errno;
        }
    }
    if (!result && mode >= 0 && lock >= 0) {
        struct stat actual;
        if (fstatat(root, ".onlinefix-phasmophobia.lock", &actual, AT_SYMLINK_NOFOLLOW) < 0) result = errno;
        else if (actual.st_dev != lock_info.st_dev || actual.st_ino != lock_info.st_ino) result = ESTALE;
        else if (unlinkat(root, ".onlinefix-phasmophobia.lock", 0) < 0 || fsync(root) < 0) result = errno;
    }
    for (size_t i = 0; i < 2; ++i) {
        if (files[i].fd >= 0) close(files[i].fd);
        if (files[i].backup >= 0) close(files[i].backup);
        if (files[i].parent >= 0) close(files[i].parent);
    }
    if (metadata >= 0) close(metadata);
    if (metadata_parent >= 0) close(metadata_parent);
    if (lock >= 0) close(lock);
    if (backup_parent >= 0) close(backup_parent);
    close(root);
    return result;
}

int of_phasmophobia_patch(const char *directory, const char *app_id, bool enabled) {
    return ph_apply(directory, app_id, enabled ? 1 : 0, NULL);
}

int of_phasmophobia_status(const char *directory, char app_id[37]) {
    if (!app_id) return EINVAL;
    app_id[0] = 0;
    return ph_apply(directory, NULL, -1, app_id);
}
