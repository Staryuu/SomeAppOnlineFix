#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <unistd.h>

static char binary_hash[65], resource_hash[65], metadata_hash[65];
static bool fallback_copy;
static int write_failure;
static int test_clone(int source, int directory, const char *path, uint32_t flags) {
    if (fallback_copy) { errno = ENOTSUP; return -1; }
    return fclonefileat(source, directory, path, flags);
}
static ssize_t test_pwrite(int fd, const void *data, size_t size, off_t offset) {
    if (write_failure == 1 && offset == 128 && size == 36) {
        write_failure = 2;
        return pwrite(fd, data, 7, offset);
    }
    if (write_failure == 2) { write_failure = 0; errno = EIO; return -1; }
    return pwrite(fd, data, size, offset);
}

#define PHASM_BINARY_HASH binary_hash
#define PHASM_RESOURCE_HASH resource_hash
#define PHASM_METADATA_HASH metadata_hash
#define PHASM_AUTH_RVA 0x1023u
#define PHASM_RESOURCE_OFFSET 128u
#define fclonefileat test_clone
#define pwrite test_pwrite
#include "../src/patch/gamespecific/phasmophobia.c"
#undef fclonefileat
#undef pwrite

static void put32(unsigned char *p, uint32_t value) { memcpy(p, &value, 4); }
static void put16(unsigned char *p, uint16_t value) { memcpy(p, &value, 2); }
static void digest(const unsigned char *data, size_t size, char hex[65]) {
    unsigned char hash[32]; CC_SHA256(data, (CC_LONG)size, hash);
    for (size_t i = 0; i < sizeof(hash); ++i) snprintf(hex + 2 * i, 3, "%02x", hash[i]);
}
static void fixture(const char *path, const void *data, size_t size) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0755);
    assert(fd >= 0 && ph_write(fd, data, size, 0) == 0 && close(fd) == 0);
}
static void matches(const char *path, const void *expected, size_t size) {
    unsigned char actual[1024]; struct stat info;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    assert(size <= sizeof(actual) && fd >= 0 && fstat(fd, &info) == 0 && (size_t)info.st_size == size);
    assert(ph_read(fd, actual, size, 0) == 0 && !memcmp(actual, expected, size));
    close(fd);
}
static int cleanup(const char *path, const struct stat *info, int flag, struct FTW *walk) { return remove(path); }

int main(void) {
    const char id[] = "12345678-1234-4321-abcd-123456789abc";
    char root[] = "/private/tmp/onlinefix-phasmophobia-XXXXXX";
    assert(mkdtemp(root));
    char data[PATH_MAX], il2cpp[PATH_MAX], directory[PATH_MAX], binary[PATH_MAX], resource[PATH_MAX], metadata[PATH_MAX];
    char binary_backup[PATH_MAX], resource_backup[PATH_MAX], lock_path[PATH_MAX], link_path[PATH_MAX];
    char legacy_binary[PATH_MAX], legacy_resource[PATH_MAX];
    snprintf(data, sizeof(data), "%s/Phasmophobia_Data", root); assert(mkdir(data, 0755) == 0);
    snprintf(il2cpp, sizeof(il2cpp), "%s/il2cpp_data", data); assert(mkdir(il2cpp, 0755) == 0);
    snprintf(directory, sizeof(directory), "%s/Metadata", il2cpp); assert(mkdir(directory, 0755) == 0);
    snprintf(binary, sizeof(binary), "%s/GameAssembly.dll", root);
    snprintf(resource, sizeof(resource), "%s/resources.assets", data);
    snprintf(metadata, sizeof(metadata), "%s/global-metadata.dat", directory);
    snprintf(binary_backup, sizeof(binary_backup), "%s.onlinefix-phasmophobia-GameAssembly.dll.backup", root);
    snprintf(legacy_binary, sizeof(legacy_binary), "%s.onlinefix-phasmophobia-backup", binary);
    snprintf(resource_backup, sizeof(resource_backup), "%s.onlinefix-phasmophobia-resources.assets.backup", root);
    snprintf(legacy_resource, sizeof(legacy_resource), "%s.onlinefix-phasmophobia-backup", resource);
    snprintf(lock_path, sizeof(lock_path), "%s/.onlinefix-phasmophobia.lock", root);
    snprintf(link_path, sizeof(link_path), "%s/hardlink", root);
    unsigned char original_binary[1024] = {0}, original_resource[512] = {0}, original_metadata[256] = {0};
    memcpy(original_binary, "MZ", 2); put32(original_binary + 60, 0x80);
    memcpy(original_binary + 0x80, "PE\0\0", 4); put16(original_binary + 0x84, 0x8664);
    put16(original_binary + 0x86, 1); put16(original_binary + 0x94, 64); put16(original_binary + 0x98, 0x20b);
    memcpy(original_binary + 0xd8, "il2cpp", 6); put32(original_binary + 0xe4, 0x1000);
    put32(original_binary + 0xe8, 512); put32(original_binary + 0xec, 512); put32(original_binary + 0xfc, 0x60000020);
    memcpy(original_binary + 0x223, ph_auth, 4);
    put32(original_resource + 124, 36); memcpy(original_resource + 128, ph_appid, 36);
    put32(original_metadata, 0xfab11baf); put32(original_metadata + 4, 31);
    digest(original_binary, sizeof(original_binary), binary_hash);
    digest(original_resource, sizeof(original_resource), resource_hash);
    digest(original_metadata, sizeof(original_metadata), metadata_hash);
    fixture(binary, original_binary, sizeof(original_binary)); fixture(resource, original_resource, sizeof(original_resource));
    fixture(metadata, original_metadata, sizeof(original_metadata));
    unsigned char patched_binary[1024], patched_resource[512];
    memcpy(patched_binary, original_binary, sizeof(patched_binary)); patched_binary[0x226] = 0xff;
    memcpy(patched_resource, original_resource, sizeof(patched_resource)); memcpy(patched_resource + 128, id, 36);

    assert(of_phasmophobia_patch(NULL, id, true) == EINVAL);
    assert(of_phasmophobia_patch(root, NULL, true) == EINVAL);
    assert(of_phasmophobia_patch(root, "invalid", true) == EINVAL);
    assert(of_phasmophobia_patch(root, ph_appid, true) == EINVAL);
    char status_id[37];
    assert(of_phasmophobia_status(root, NULL) == EINVAL);
    assert(of_phasmophobia_status(root, status_id) == 0 && !*status_id);
    assert(access(lock_path, F_OK) < 0);
    assert(access(binary_backup, F_OK) < 0 && access(resource_backup, F_OK) < 0);
    assert(of_phasmophobia_patch(root, NULL, false) == 0);
    assert(of_phasmophobia_patch(root, id, true) == 0);
    assert(access(lock_path, F_OK) < 0 && access(legacy_binary, F_OK) < 0 && access(legacy_resource, F_OK) < 0);
    matches(binary, patched_binary, sizeof(patched_binary)); matches(resource, patched_resource, sizeof(patched_resource));
    matches(binary_backup, original_binary, sizeof(original_binary)); matches(resource_backup, original_resource, sizeof(original_resource));
    assert(of_phasmophobia_status(root, status_id) == 0 && !strcmp(status_id, id));
    assert(of_phasmophobia_patch(root, id, true) == 0);
    const char alternate[] = "abcdefab-1234-4321-abcd-123456789abc";
    assert(of_phasmophobia_patch(root, alternate, true) == 0);
    assert(of_phasmophobia_status(root, status_id) == 0 && !strcmp(status_id, alternate));
    matches(binary_backup, original_binary, sizeof(original_binary)); matches(resource_backup, original_resource, sizeof(original_resource));
    assert(of_phasmophobia_patch(root, id, true) == 0);
    assert(of_phasmophobia_patch(root, NULL, false) == 0);
    matches(binary, original_binary, sizeof(original_binary)); matches(resource, original_resource, sizeof(original_resource));
    assert(access(binary_backup, F_OK) < 0 && access(resource_backup, F_OK) < 0);
    assert(of_phasmophobia_status(root, status_id) == 0 && !*status_id);
    assert(access(lock_path, F_OK) < 0);

    fallback_copy = true; write_failure = 1;
    assert(of_phasmophobia_patch(root, id, true) == EIO && write_failure == 0);
    matches(binary, original_binary, sizeof(original_binary)); matches(resource, original_resource, sizeof(original_resource));
    matches(binary_backup, original_binary, sizeof(original_binary)); matches(resource_backup, original_resource, sizeof(original_resource));
    assert(of_phasmophobia_patch(root, id, true) == 0);
    fixture(binary, original_binary, sizeof(original_binary));
    assert(of_phasmophobia_status(root, status_id) == ESTALE);
    assert(of_phasmophobia_patch(root, id, true) == 0);
    matches(binary, patched_binary, sizeof(patched_binary));
    fixture(resource, original_resource, sizeof(original_resource));
    assert(of_phasmophobia_patch(root, NULL, false) == 0);
    matches(binary, original_binary, sizeof(original_binary)); matches(resource, original_resource, sizeof(original_resource));

    assert(of_phasmophobia_patch(root, id, true) == 0);
    patched_resource[300] ^= 1; fixture(resource, patched_resource, sizeof(patched_resource));
    assert(of_phasmophobia_status(root, status_id) == ESTALE);
    assert(of_phasmophobia_patch(root, NULL, false) == ESTALE);
    matches(binary, patched_binary, sizeof(patched_binary)); matches(resource, patched_resource, sizeof(patched_resource));
    patched_resource[300] ^= 1; fixture(resource, patched_resource, sizeof(patched_resource));
    assert(of_phasmophobia_patch(root, NULL, false) == 0);
    original_metadata[20] = 1; fixture(metadata, original_metadata, sizeof(original_metadata));
    assert(of_phasmophobia_patch(root, id, true) == ENOTSUP);
    original_metadata[20] = 0; fixture(metadata, original_metadata, sizeof(original_metadata));

    assert(symlink(binary, binary_backup) == 0);
    assert(of_phasmophobia_patch(root, id, true) == ELOOP); assert(unlink(binary_backup) == 0);
    assert(link(resource, link_path) == 0);
    assert(of_phasmophobia_patch(root, id, true) == ENOTSUP); assert(unlink(link_path) == 0);
    assert(unlink(resource) == 0 && symlink(binary, resource) == 0);
    assert(of_phasmophobia_patch(root, id, true) == ELOOP); assert(unlink(resource) == 0);
    fixture(resource, original_resource, sizeof(original_resource));
    int lock = open(root, O_RDONLY | O_DIRECTORY); assert(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0);
    assert(of_phasmophobia_patch(root, id, true) == EWOULDBLOCK); close(lock);
    fixture(binary, patched_binary, sizeof(patched_binary));
    assert(of_phasmophobia_patch(root, NULL, false) == ESTALE);
    fixture(binary, original_binary, sizeof(original_binary));
    assert(of_phasmophobia_patch(root, id, true) == 0);
    write_failure = 1; assert(of_phasmophobia_patch(root, NULL, false) == EIO);
    matches(binary, patched_binary, sizeof(patched_binary)); matches(resource, patched_resource, sizeof(patched_resource));
    assert(of_phasmophobia_patch(root, NULL, false) == 0);
    // Old installations restore without leaving the old lock or either backup.
    fixture(binary, patched_binary, sizeof(patched_binary));
    fixture(resource, patched_resource, sizeof(patched_resource));
    fixture(legacy_binary, original_binary, sizeof(original_binary));
    fixture(legacy_resource, original_resource, sizeof(original_resource));
    fixture(lock_path, "", 0);
    assert(of_phasmophobia_status(root, status_id) == 0 && !strcmp(status_id, id));
    assert(access(lock_path, F_OK) == 0); // Status must not alter existing artifacts.
    assert(of_phasmophobia_patch(root, NULL, false) == 0);
    matches(binary, original_binary, sizeof(original_binary)); matches(resource, original_resource, sizeof(original_resource));
    assert(access(lock_path, F_OK) < 0 && access(legacy_binary, F_OK) < 0 && access(legacy_resource, F_OK) < 0);
    assert(of_phasmophobia_status(root, status_id) == 0 && !*status_id);
    assert(access(lock_path, F_OK) < 0);

    // Applying to an old installation migrates the validated backups outside the game.
    fixture(binary, patched_binary, sizeof(patched_binary));
    fixture(resource, patched_resource, sizeof(patched_resource));
    fixture(legacy_binary, original_binary, sizeof(original_binary));
    fixture(legacy_resource, original_resource, sizeof(original_resource));
    fixture(lock_path, "", 0);
    lock = open(lock_path, O_RDWR); assert(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0);
    assert(of_phasmophobia_patch(root, id, true) == EWOULDBLOCK); close(lock);
    assert(of_phasmophobia_patch(root, id, true) == 0);
    matches(binary_backup, original_binary, sizeof(original_binary)); matches(resource_backup, original_resource, sizeof(original_resource));
    assert(access(lock_path, F_OK) < 0 && access(legacy_binary, F_OK) < 0 && access(legacy_resource, F_OK) < 0);
    fixture(legacy_binary, original_binary, sizeof(original_binary));
    assert(of_phasmophobia_status(root, status_id) == ESTALE);
    assert(of_phasmophobia_patch(root, NULL, false) == ESTALE);
    matches(binary, patched_binary, sizeof(patched_binary));
    assert(unlink(legacy_binary) == 0);
    assert(of_phasmophobia_patch(root, NULL, false) == 0);
    assert(access(binary_backup, F_OK) < 0 && access(resource_backup, F_OK) < 0);
    fixture(lock_path, "unrelated", 9);
    assert(of_phasmophobia_patch(root, NULL, false) == ENOTSUP);
    matches(lock_path, "unrelated", 9);
    assert(unlink(lock_path) == 0);
    assert(nftw(root, cleanup, 16, FTW_DEPTH | FTW_PHYS) == 0);
    puts("Phasmophobia native checks passed: clean status/apply/restore, external backups, legacy restore/migration, backup collision and unknown-lock preservation, PE mapping, idempotence, clone/fallback, partial-write rollback, partial-pair recovery, build/GUID/symlink/hardlink and directory/legacy lock guards.");
    return 0;
}
