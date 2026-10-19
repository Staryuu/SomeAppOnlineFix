#include <assert.h>
#include <errno.h>
#include <fcntl.h>
#include <ftw.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static char fixture_hash[65];
static int write_failure;
static ssize_t test_pwrite(int fd, const void *data, size_t size, off_t offset) {
    if (write_failure == 1 && offset == 128 && size == 72) {
        write_failure = 2;
        return pwrite(fd, data, 7, offset);
    }
    if (write_failure == 2) { write_failure = 0; errno = EIO; return -1; }
    return pwrite(fd, data, size, offset);
}
#define REPO_HASH fixture_hash
#define REPO_SIZE 512u
#define REPO_PUN_OFFSET 128u
#define REPO_VOICE_OFFSET 224u
#define REPO_AUTH_OFFSET 32u
#define pwrite test_pwrite
#include "../src/patch/gamespecific/repo.c"
#undef pwrite

static void fixture(const char *path, const unsigned char *data) {
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0600);
    assert(fd >= 0 && repo_write(fd, data, REPO_SIZE, 0) == 0 && close(fd) == 0);
}
static void matches(const char *path, const unsigned char *expected) {
    unsigned char data[REPO_SIZE];
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    assert(fd >= 0 && repo_read(fd, data) == 0 && !memcmp(data, expected, REPO_SIZE));
    close(fd);
}
static int cleanup(const char *path, const struct stat *info, int flag, struct FTW *walk) { return remove(path); }

int main(void) {
    const char *pun = "12345678-1234-4321-abcd-123456789abc", *voice = "87654321-4321-4321-abcd-cba987654321";
    assert(of_repo_validate_ids(pun, "") && of_repo_validate_ids(pun, voice));
    assert(!of_repo_validate_ids(NULL, "") && !of_repo_validate_ids(pun, NULL));
    assert(!of_repo_validate_ids("", voice) && !of_repo_validate_ids("bad", ""));
    assert(!of_repo_validate_ids(pun, pun) && !of_repo_validate_ids(pun, "bad"));
    assert(!of_repo_validate_ids(repo_original_ids[0], "") && !of_repo_validate_ids(pun, repo_original_ids[1]));
    char root[] = "/private/tmp/onlinefix-repo-XXXXXX";
    assert(mkdtemp(root));
    char data_dir[PATH_MAX], managed[PATH_MAX], assembly[PATH_MAX], backup[PATH_MAX], link[PATH_MAX];
    snprintf(data_dir, sizeof(data_dir), "%s/REPO_Data", root); assert(mkdir(data_dir, 0755) == 0);
    snprintf(managed, sizeof(managed), "%s/Managed", data_dir); assert(mkdir(managed, 0755) == 0);
    snprintf(assembly, sizeof(assembly), "%s/Assembly-CSharp.dll", managed);
    snprintf(backup, sizeof(backup), "%s.onlinefix-repo-Assembly-CSharp.dll.backup", root);
    snprintf(link, sizeof(link), "%s/hardlink", root);
    unsigned char original[REPO_SIZE] = {0}, patched[REPO_SIZE], dual[REPO_SIZE], damaged[REPO_SIZE];
    memcpy(original, "MZ", 2);
    repo_encode(original + REPO_PUN_OFFSET, repo_original_ids[0]);
    repo_encode(original + REPO_VOICE_OFFSET, repo_original_ids[1]);
    memcpy(original + REPO_AUTH_OFFSET, repo_auth, sizeof(repo_auth));
    unsigned char hash[32]; CC_SHA256(original, REPO_SIZE, hash);
    for (size_t i = 0; i < sizeof(hash); ++i) snprintf(fixture_hash + i * 2, 3, "%02x", hash[i]);
    memcpy(patched, original, REPO_SIZE);
    repo_encode(patched + REPO_PUN_OFFSET, pun);
    memcpy(patched + REPO_AUTH_OFFSET, repo_no_auth, sizeof(repo_no_auth));
    memcpy(dual, patched, REPO_SIZE); repo_encode(dual + REPO_VOICE_OFFSET, voice);
    fixture(assembly, original);
    char status_pun[37], status_voice[37];
    assert(of_repo_status(NULL, status_pun, status_voice) == EINVAL);
    assert(of_repo_status(root, NULL, status_voice) == EINVAL);
    assert(of_repo_patch(root, "bad", "", true) == EINVAL);
    assert(of_repo_status(root, status_pun, status_voice) == 0 && !*status_pun && !*status_voice);
    assert(of_repo_patch(root, pun, "", true) == 0);
    matches(assembly, patched); matches(backup, original);
    struct stat info; assert(stat(backup, &info) == 0 && (info.st_mode & 0777) == 0600);
    assert(of_repo_status(root, status_pun, status_voice) == 0 && !strcmp(status_pun, pun) && !*status_voice);
    assert(of_repo_patch(root, pun, "", true) == 0); matches(assembly, patched);
    assert(of_repo_patch(root, pun, voice, true) == 0); matches(assembly, dual);
    assert(of_repo_status(root, status_pun, status_voice) == 0 && !strcmp(status_voice, voice));
    assert(of_repo_patch(root, pun, "", true) == 0); matches(assembly, patched);
    assert(of_repo_patch(root, NULL, NULL, false) == 0); matches(assembly, original);
    assert(access(backup, F_OK) < 0 && errno == ENOENT);
    assert(of_repo_patch(root, NULL, NULL, false) == 0);

    write_failure = 1;
    assert(of_repo_patch(root, pun, "", true) == EIO && write_failure == 0);
    matches(assembly, original); matches(backup, original);
    assert(of_repo_patch(root, pun, "", true) == 0);
    write_failure = 1;
    assert(of_repo_patch(root, NULL, NULL, false) == EIO && write_failure == 0);
    matches(assembly, patched); matches(backup, original);
    assert(of_repo_patch(root, NULL, NULL, false) == 0);
    assert(of_repo_patch(root, pun, "", true) == 0);
    assert(unlink(backup) == 0);
    assert(of_repo_status(root, status_pun, status_voice) == ESTALE);
    assert(of_repo_patch(root, NULL, NULL, false) == ESTALE); matches(assembly, patched);
    fixture(backup, original);
    memcpy(damaged, original, REPO_SIZE); damaged[10] ^= 1; fixture(backup, damaged);
    assert(of_repo_patch(root, NULL, NULL, false) == ESTALE); matches(assembly, patched);
    fixture(backup, original);
    memcpy(damaged, patched, REPO_SIZE); damaged[REPO_AUTH_OFFSET] ^= 1; fixture(assembly, damaged);
    assert(of_repo_status(root, status_pun, status_voice) == ESTALE);
    fixture(assembly, patched);
    assert(of_repo_patch(root, NULL, NULL, false) == 0);
    memcpy(damaged, original, REPO_SIZE); damaged[10] ^= 1; fixture(assembly, damaged);
    assert(of_repo_patch(root, pun, "", true) == ENOTSUP); matches(assembly, damaged);
    fixture(assembly, original);
    assert(symlink(assembly, backup) == 0);
    assert(of_repo_patch(root, pun, "", true) == ELOOP); assert(unlink(backup) == 0);
    assert(linkat(AT_FDCWD, assembly, AT_FDCWD, link, 0) == 0);
    assert(of_repo_patch(root, pun, "", true) == ENOTSUP); assert(unlink(link) == 0);
    assert(rename(assembly, link) == 0 && symlink(link, assembly) == 0);
    assert(of_repo_patch(root, pun, "", true) == ELOOP);
    assert(unlink(assembly) == 0 && rename(link, assembly) == 0);
    int lock = open(root, O_RDONLY | O_DIRECTORY);
    assert(lock >= 0 && flock(lock, LOCK_EX | LOCK_NB) == 0);
    assert(of_repo_patch(root, pun, "", true) == EWOULDBLOCK); close(lock);
    matches(assembly, original);
    assert(nftw(root, cleanup, 16, FTW_DEPTH | FTW_PHYS) == 0);
    puts("R.E.P.O. native checks passed: PUN-only/dual status and restore, original voice preservation, backup permissions/validation, write rollback, build/GUID/symlink/hardlink and lock guards.");
    return 0;
}
