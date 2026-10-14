#include "patch.h"
#include "../../vendor/cJSON.h"
#include <stddef.h>
#include <string.h>

bool of_patches_read(const cJSON *json, OFPatches *patches) {
    *patches = OF_DEFAULT_PATCHES;
    if (!json) return true;
    if (!cJSON_IsObject(json)) return false;
    struct { const char *name; bool *value; } fields[] = {
        {"startupAppID", &patches->startup_id}, {"overlayAppID", &patches->overlay_id},
        {"inputAppID", &patches->input_id}, {"statsAppID", &patches->stats_id},
        {"terrariaServerEnvironment", &patches->terraria_server},
    };
    unsigned seen = 0;
    const cJSON *entry;
    cJSON_ArrayForEach(entry, json) {
        bool known = false;
        for (size_t i = 0; i < sizeof(fields) / sizeof(fields[0]); ++i) {
            if (!strcmp(entry->string, fields[i].name)) {
                if (!cJSON_IsBool(entry) || (seen & (1u << i))) return false;
                seen |= 1u << i;
                *fields[i].value = cJSON_IsTrue(entry);
                known = true;
                break;
            }
        }
        if (!known) return false;
    }
    return true;
}
