#include <assert.h>
#include <errno.h>
#include <ftw.h>
#include <spawn.h>
#include <stdbool.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static bool signing_fails, replacement_fails;
static const char *binary_path;
static int test_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                      const posix_spawnattr_t *attributes, char *const arguments[], char *const environment[]) {
    if (signing_fails) return EIO;
    *pid = fork();
    if (*pid == 0) _exit(0);
    return *pid < 0 ? errno : 0;
}
static int test_rename(const char *from, const char *to) {
    if (replacement_fails && !strcmp(to, binary_path)) { replacement_fails = false; errno = EIO; return -1; }
    return rename(from, to);
}

#define PICO_METADATA_HASH "a6440b94fae4761a1fbdbeb803cd45bedf1c3f9dd0b5b07d5bdae25ffb2d1237"
#define PICO_BINARY_HASH "90a246f6b7945c48f82b931aab83dd0016f945c81be5ad17c23236aea4283d0e"
#define PICO_AUTH_OFFSET 128u
#define posix_spawn test_spawn
#define rename test_rename
#include "../src/patch/gamespecific/pico_park_2.c"
#undef posix_spawn
#undef rename

static const char photon_host[] = "ns.photonengine.io";
static void put32(unsigned char *data, uint32_t value) { memcpy(data, &value, 4); }

static void write_fixture(const char *path, const PicoBlob *blob) {
    int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0755);
    assert(fd >= 0 && pico_write(fd, blob) == 0 && close(fd) == 0);
}
static void check_file(const char *path, const PicoBlob *expected) {
    PicoBlob actual = {0};
    assert(pico_read(path, &actual) == 0 && pico_equal(&actual, expected));
    free(actual.data);
}
static void make_directory(const char *path) {
    char parent[PATH_MAX];
    assert(strlen(path) < sizeof(parent)); strcpy(parent, path);
    for (char *p = parent + 1; *p; ++p) {
        if (*p != '/') continue;
        *p = '\0'; assert(mkdir(parent, 0755) == 0 || errno == EEXIST); *p = '/';
    }
    assert(mkdir(parent, 0755) == 0 || errno == EEXIST);
}
static int remove_fixture(const char *path, const struct stat *info, int flag, struct FTW *walk) { return remove(path); }

int main(void) {
    char root[] = "/private/tmp/onlinefix-pico-XXXXXX";
    assert(mkdtemp(root));
    char app[PATH_MAX], metadata[PATH_MAX], binary[PATH_MAX], info[PATH_MAX], metadata_backup[PATH_MAX], binary_backup[PATH_MAX], lock_path[PATH_MAX];
    snprintf(app, sizeof(app), "%s/pico_park_2.app", root);
    snprintf(metadata, sizeof(metadata), "%s/Contents/Resources/Data/il2cpp_data/Metadata", app); make_directory(metadata);
    snprintf(binary, sizeof(binary), "%s/Contents/Frameworks", app); make_directory(binary);
    snprintf(metadata, sizeof(metadata), "%s/Contents/Resources/Data/il2cpp_data/Metadata/global-metadata.dat", app);
    snprintf(binary, sizeof(binary), "%s/Contents/Frameworks/GameAssembly.dylib", app); binary_path = binary;
    snprintf(info, sizeof(info), "%s/Contents/Info.plist", app);
    snprintf(metadata_backup, sizeof(metadata_backup), "%s.onlinefix-endpoint-backup.dat", app);
    snprintf(binary_backup, sizeof(binary_backup), "%s.onlinefix-auth-backup.dylib", app);
    snprintf(lock_path, sizeof(lock_path), "%s.onlinefix-endpoint.lock", app);
    unsigned char plist[] = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.tecopark.picopark2</string></dict></plist>";
    PicoBlob bundle_info = {.data = plist, .size = sizeof(plist) - 1}; write_fixture(info, &bundle_info);

    size_t pool = 256 + 25890 * 8, pool_size = 9 + sizeof(photon_host) - 1 + sizeof(old_id) - 1;
    PicoBlob original_metadata = {.size = pool + pool_size}, original_binary = {.size = 256};
    original_metadata.data = calloc(1, original_metadata.size); original_binary.data = calloc(1, original_binary.size);
    assert(original_metadata.data && original_binary.data);
    put32(original_metadata.data, 0xfab11baf); put32(original_metadata.data + 4, 29);
    put32(original_metadata.data + 8, 256); put32(original_metadata.data + 12, 25890 * 8);
    put32(original_metadata.data + 16, (uint32_t)pool); put32(original_metadata.data + 20, (uint32_t)pool_size);
    put32(original_metadata.data + 256, 9);
    put32(original_metadata.data + 256 + 2763 * 8, sizeof(old_id) - 1);
    put32(original_metadata.data + 256 + 2763 * 8 + 4, 9 + sizeof(photon_host) - 1);
    put32(original_metadata.data + 256 + 25889 * 8, sizeof(photon_host) - 1);
    put32(original_metadata.data + 256 + 25889 * 8 + 4, 9);
    memcpy(original_metadata.data + pool, "unrelated", 9);
    memcpy(original_metadata.data + pool + 9, photon_host, sizeof(photon_host) - 1);
    memcpy(original_metadata.data + pool + 9 + sizeof(photon_host) - 1, old_id, sizeof(old_id) - 1);
    memcpy(original_binary.data, "test binary", 11); memcpy(original_binary.data + PICO_AUTH_OFFSET, steam_auth, 4);
    assert(pico_hash(&original_metadata, PICO_METADATA_HASH) && pico_hash(&original_binary, PICO_BINARY_HASH));
    write_fixture(metadata, &original_metadata); write_fixture(binary, &original_binary);

    bool enabled = true;
    assert(of_pico_park_2_status(app, &enabled) == 0 && !enabled);
    assert(access(metadata_backup, F_OK) < 0 && access(binary_backup, F_OK) < 0);
    assert(of_pico_park_2_patch(app, true) == 0);
    assert(of_pico_park_2_status(app, &enabled) == 0 && enabled);
    check_file(metadata_backup, &original_metadata); check_file(binary_backup, &original_binary);
    PicoBlob patched_metadata = {0}, patched_binary = {0};
    assert(pico_read(metadata, &patched_metadata) == 0 && pico_read(binary, &patched_binary) == 0);
    assert(patched_metadata.size == original_metadata.size && patched_binary.size == original_binary.size);
    assert(!memcmp(patched_metadata.data + pool + 9 + sizeof(photon_host) - 1, new_id, sizeof(new_id) - 1));
    assert(!memcmp(patched_binary.data + PICO_AUTH_OFFSET, no_auth, 4));
    assert(of_pico_park_2_patch(app, true) == 0);
    check_file(metadata, &patched_metadata); check_file(binary, &patched_binary);
    assert(of_pico_park_2_patch(app, false) == 0);
    check_file(metadata, &original_metadata); check_file(binary, &original_binary);
    assert(access(metadata_backup, F_OK) < 0 && access(binary_backup, F_OK) < 0);
    assert(of_pico_park_2_patch(app, false) == 0);

    signing_fails = true;
    assert(of_pico_park_2_patch(app, true) == EIO);
    check_file(metadata, &original_metadata); check_file(binary, &original_binary);
    assert(access(metadata_backup, F_OK) < 0 && access(binary_backup, F_OK) < 0);
    signing_fails = false; replacement_fails = true;
    assert(of_pico_park_2_patch(app, true) == EIO);
    check_file(metadata, &original_metadata); check_file(binary, &original_binary);
    check_file(metadata_backup, &original_metadata); check_file(binary_backup, &original_binary);
    assert(of_pico_park_2_patch(app, false) == 0);

    assert(of_pico_park_2_patch(app, true) == 0);
    write_fixture(binary, &original_binary);
    assert(of_pico_park_2_status(app, &enabled) == ESTALE);
    assert(of_pico_park_2_patch(app, true) == 0);
    patched_binary.data[0] ^= 1; write_fixture(binary, &patched_binary);
    assert(of_pico_park_2_patch(app, false) == ESTALE && of_pico_park_2_patch(app, true) == ESTALE);
    check_file(binary, &patched_binary); check_file(metadata, &patched_metadata);
    check_file(binary_backup, &original_binary);
    patched_binary.data[0] ^= 1; write_fixture(binary, &patched_binary);
    assert(of_pico_park_2_patch(app, false) == 0);

    assert(symlink(binary, binary_backup) == 0);
    assert(of_pico_park_2_patch(app, true) == ELOOP);
    assert(access(metadata_backup, F_OK) < 0); assert(unlink(binary_backup) == 0);
    int lock = open(lock_path, O_RDWR); assert(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0);
    assert(of_pico_park_2_patch(app, true) == EWOULDBLOCK); close(lock);
    assert(of_pico_park_2_patch(NULL, true) == EINVAL && of_pico_park_2_status(app, NULL) == EINVAL);
    *strstr((char *)plist, "com.tecopark.picopark2") = 'x';
    write_fixture(info, &bundle_info); assert(of_pico_park_2_patch(app, true) == ENOTSUP);

    free(original_metadata.data); free(original_binary.data); free(patched_metadata.data); free(patched_binary.data);
    assert(nftw(root, remove_fixture, 16, FTW_DEPTH | FTW_PHYS) == 0);
    puts("PICO PARK 2 native checks passed: status, exact restore, signing failure, write rollback, partial repair, update preservation, symlinks, lock and bundle validation.");
    return 0;
}
