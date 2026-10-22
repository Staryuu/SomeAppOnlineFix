#include "onlinefix.h"
#include "../vendor/cJSON.h"
#include <ctype.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <regex.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static bool code_region(const unsigned char **code, size_t *length, const char **path) {
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char *image = _dyld_get_image_name(i);
        const char *base = image ? strrchr(image, '/') : NULL;
        if (!image || strcmp(base ? base + 1 : image, "steamclient.dylib")) continue;
        const struct mach_header_64 *h = (const void *)_dyld_get_image_header(i);
        if (h->magic != MH_MAGIC_64 || h->cputype != CPU_TYPE_ARM64) return false;
        const unsigned char *p = (const void *)(h + 1), *end = p + h->sizeofcmds;
        for (uint32_t j = 0; j < h->ncmds && (size_t)(end - p) >= sizeof(struct load_command); ++j) {
            const struct load_command *cmd = (const void *)p;
            if (cmd->cmdsize < sizeof(*cmd) || cmd->cmdsize > (size_t)(end - p)) return false;
            if (cmd->cmd == LC_SEGMENT_64 && cmd->cmdsize >= sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg = (const void *)p;
                if (seg->nsects > (cmd->cmdsize - sizeof(*seg)) / sizeof(struct section_64)) return false;
                const struct section_64 *sections = (const void *)(seg + 1);
                for (uint32_t k = 0; k < seg->nsects; ++k) {
                    if (!strncmp(sections[k].sectname, "__text", 16) &&
                        !strncmp(sections[k].segname, "__TEXT", 16)) {
                        *code = (const void *)(sections[k].addr + _dyld_get_image_vmaddr_slide(i));
                        *length = sections[k].size;
                        *path = image;
                        return true;
                    }
                }
            }
            p += cmd->cmdsize;
        }
    }
    return false;
}

static int nibble(char c) {
    const char *digits = "0123456789abcdef";
    const char *p = c ? strchr(digits, tolower((unsigned char)c)) : NULL;
    return p ? (int)(p - digits) : -1;
}

// Profiles use whitespace-separated hex bytes or ??; only aligned, unique hits are accepted.
static const unsigned char *match(const unsigned char *code, size_t size, const char *pattern) {
    unsigned char bytes[4096], fixed[4096];
    size_t n = 0;
    bool has_fixed = false;
    if (!pattern) return NULL;
    while (*pattern) {
        while (isspace((unsigned char)*pattern)) ++pattern;
        if (!*pattern) break;
        if (!pattern[1] || n == sizeof(bytes)) return NULL;
        if (pattern[0] == '?' && pattern[1] == '?') { bytes[n] = 0; fixed[n] = 0; }
        else {
            int a = nibble(pattern[0]), b = nibble(pattern[1]);
            if (a < 0 || b < 0) return NULL;
            bytes[n] = (unsigned char)(a * 16 + b); fixed[n] = 1; has_fixed = true;
        }
        ++n; pattern += 2;
        if (*pattern && !isspace((unsigned char)*pattern)) return NULL;
    }
    if (!n || n > size || !has_fixed) return NULL;
    const unsigned char *found = NULL;
    for (size_t offset = 0; offset <= size - n; offset += 4) {
        size_t j = 0;
        while (j < n && (!fixed[j] || code[offset + j] == bytes[j])) ++j;
        if (j != n) continue;
        if (found) return NULL;
        found = code + offset;
    }
    return found;
}

static uint32_t client_build(const char *path) {
    const char *slash = strrchr(path, '/');
    if (!slash || slash - path >= PATH_MAX) return 0;
    char manifest[PATH_MAX], version[11] = {0};
    uint64_t build = 0;
    const char *variants[] = {"steam_client_signed-2_osx", "steam_client_signed_osx", "steam_client_osx"};
    struct stat newest = {0};
    bool found = false;
    for (size_t i = 0; i < sizeof(variants) / sizeof(variants[0]); ++i) {
        char candidate[PATH_MAX];
        struct stat info;
        int written = snprintf(candidate, sizeof(candidate), "%.*s/package/%s.manifest", (int)(slash - path), path, variants[i]);
        if (written < 0 || (size_t)written >= sizeof(candidate)) return 0;
        if (stat(candidate, &info)) continue;
        if (!found || info.st_mtimespec.tv_sec > newest.st_mtimespec.tv_sec ||
            (info.st_mtimespec.tv_sec == newest.st_mtimespec.tv_sec && info.st_mtimespec.tv_nsec > newest.st_mtimespec.tv_nsec)) {
            strcpy(manifest, candidate); newest = info; found = true;
        }
    }
    if (!found) return 0;
    FILE *file = fopen(manifest, "rb");
    if (!file) return 0;
    char *raw = calloc(1024 * 1024 + 1, 1);
    if (!raw) { fclose(file); return 0; }
    size_t length = fread(raw, 1, 1024 * 1024 + 1, file);
    bool valid = !ferror(file) && length > 0 && length <= 1024 * 1024 && !memchr(raw, '\0', length);
    fclose(file);
    regex_t expression;
    if (valid && regcomp(&expression, "\"version\"[[:space:]]*\"([^\"]*)\"", REG_EXTENDED) == 0) {
        regmatch_t hit[2];
        // shortcut: manifests may be cached; of_resolve must also match all signatures in the loaded client.
        valid = regexec(&expression, raw, 2, hit, 0) == 0;
        if (valid) {
            size_t digits = (size_t)(hit[1].rm_eo - hit[1].rm_so);
            valid = digits > 0 && digits < sizeof(version) && raw[hit[1].rm_so] != '0' &&
                regexec(&expression, raw + hit[0].rm_eo, 0, NULL, 0) == REG_NOMATCH;
            for (size_t i = 0; valid && i < digits; ++i) {
                char digit = raw[hit[1].rm_so + i];
                valid = digit >= '0' && digit <= '9';
            }
            if (valid) {
                memcpy(version, raw + hit[1].rm_so, digits);
                build = strtoull(version, NULL, 10);
                valid = build > 0 && build <= UINT32_MAX;
            }
        }
        regfree(&expression);
    } else valid = false;
    free(raw);
    return valid ? (uint32_t)build : 0;
}

static cJSON *load_profile(const char *location, uint32_t build) {
    struct stat info;
    if (!location || !build || stat(location, &info)) return NULL;
    char path[PATH_MAX];
    const char *profile = location;
    if (S_ISDIR(info.st_mode)) {
        int length = snprintf(path, sizeof(path), "%s/%u.json", location, build);
        if (length < 0 || (size_t)length >= sizeof(path)) return NULL;
        profile = path;
    }
    FILE *file = fopen(profile, "rb");
    if (!file) { of_log("no signature profile for Steam build %u: %s", build, profile); return NULL; }
    char *raw = malloc(1024 * 1024 + 1);
    if (!raw) { fclose(file); return NULL; }
    size_t length = fread(raw, 1, 1024 * 1024 + 1, file);
    bool valid = !ferror(file) && length > 0 && length <= 1024 * 1024;
    fclose(file);
    cJSON *root = valid ? cJSON_ParseWithLength(raw, length) : NULL;
    free(raw);
    cJSON *version = cJSON_GetObjectItemCaseSensitive(root, "steam_build");
    if (!cJSON_IsNumber(version) || version->valuedouble != (double)build) {
        of_log("invalid or mismatched profile for Steam build %u: %s", build, profile);
        cJSON_Delete(root);
        return NULL;
    }
    of_log("selected Steam build %u profile: %s", build, profile);
    return root;
}

static bool resolve_targets(cJSON *root, const unsigned char *code, size_t size,
                            const char *const *names, void **addresses, size_t count) {
    cJSON *arch = cJSON_GetObjectItemCaseSensitive(root, "arch");
    cJSON *sigs = cJSON_GetObjectItemCaseSensitive(root, "signatures");
    bool valid = cJSON_IsString(arch) && !strcmp(arch->valuestring, "arm64") && cJSON_IsArray(sigs);
    for (size_t i = 0; valid && i < count; ++i) {
        cJSON *entry, *selected = NULL;
        cJSON_ArrayForEach(entry, sigs) {
            cJSON *name = cJSON_GetObjectItemCaseSensitive(entry, "name");
            if (cJSON_IsString(name) && !strcmp(name->valuestring, names[i])) {
                if (selected) { valid = false; break; }
                selected = entry;
            }
        }
        cJSON *aob = cJSON_GetObjectItemCaseSensitive(selected, "aob_hex");
        cJSON *offset = cJSON_GetObjectItemCaseSensitive(selected, "match_offset");
        double adjustment = offset ? offset->valuedouble : 0;
        const unsigned char *hit = cJSON_IsString(aob) ? match(code, size, aob->valuestring) : NULL;
        if (!valid || !hit || (offset && !cJSON_IsNumber(offset)) || adjustment < 0 ||
            adjustment > hit - code || adjustment != (double)(size_t)adjustment ||
            (size_t)adjustment % 4) {
            of_log("profile target missing, invalid or ambiguous: %s", names[i]); valid = false; break;
        }
        addresses[i] = (void *)(hit - (size_t)adjustment);
        for (size_t j = 0; j < i; ++j) if (addresses[j] == addresses[i]) valid = false;
    }
    return valid;
}

bool of_resolve(const char *profile, const char *const *names, void **addresses, size_t count) {
    const unsigned char *code;
    const char *client;
    size_t size;
    if (!profile || !code_region(&code, &size, &client)) return false;
    uint32_t build = client_build(client);
    cJSON *root = load_profile(profile, build);
    if (!root) { of_log("Steam build is unknown or unsupported; routing disabled"); return false; }
    bool valid = resolve_targets(root, code, size, names, addresses, count);
    cJSON_Delete(root);
    return valid;
}
