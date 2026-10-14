#include "onlinefix.h"
#include "../vendor/cJSON.h"
#include <stdio.h>
#include <stdlib.h>

// Read at launch time so Manager changes don't require restarting Steam.
bool of_config_game(uint32_t game, bool *keep_id, OFPatches *patches) {
    const char *path = getenv("ONLINEFIX_CONFIG");
    if (!path || !*path) return false;
    FILE *file = fopen(path, "rb");
    if (!file) { of_log("cannot read game config: %s", path); return false; }
    char *raw = malloc(1024 * 1024 + 1);
    if (!raw) { fclose(file); return false; }
    size_t size = fread(raw, 1, 1024 * 1024 + 1, file);
    bool valid = !ferror(file) && size > 0 && size <= 1024 * 1024;
    fclose(file);
    if (valid) raw[size] = '\0';
    cJSON *root = valid ? cJSON_ParseWithLengthOpts(raw, size + 1, NULL, true) : NULL;
    free(raw);
    cJSON *games = cJSON_GetObjectItemCaseSensitive(root, "games");
    valid = cJSON_IsArray(games);
    bool found = false, keep = false;
    OFPatches selected = OF_DEFAULT_PATCHES;
    cJSON *entry;
    cJSON_ArrayForEach(entry, games) {
        cJSON *id = cJSON_GetObjectItemCaseSensitive(entry, "id");
        cJSON *real = cJSON_GetObjectItemCaseSensitive(entry, "keepRealAppID");
        OFPatches parsed;
        if (!cJSON_IsNumber(id) || id->valuedouble < 1 || id->valuedouble > 0xffffff ||
            id->valuedouble != (double)id->valueint || id->valueint == 480 ||
            !cJSON_IsBool(real) || !of_patches_read(cJSON_GetObjectItemCaseSensitive(entry, "patches"), &parsed)) {
            valid = false; break;
        }
        if (parsed.terraria_server && id->valueint != 105600) { valid = false; break; }
        if ((uint32_t)id->valueint == game) {
            if (found) { valid = false; break; }
            found = true;
            keep = cJSON_IsTrue(real);
            selected = parsed;
        }
    }
    cJSON_Delete(root);
    if (!valid) of_log("invalid game config; automatic routing skipped: %s", path);
    if (valid && found) { *keep_id = keep; *patches = selected; }
    return valid && found;
}
