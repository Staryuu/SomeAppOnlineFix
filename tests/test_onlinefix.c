#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include "../src/onlinefix.h"

void of_log(const char *format, ...) { (void)format; }
#include "../src/onlinefix.c"
#include "../src/profile.c"
#include "../src/children.c"

static int calls;
int DobbyHook(void *address, void *handler, void **original) {
    (void)address; (void)handler; (void)original; ++calls; return 0;
}
int DobbyInstrument(void *address, dobby_instrument_callback_t handler) {
    (void)address; (void)handler; ++calls; return 0;
}
void *DobbySymbolResolver(const char *image, const char *name) {
    (void)image; (void)name; return NULL;
}
static uint32_t observed;
static uint32_t record_session(void *engine, uint32_t id, uint8_t update) {
    (void)engine; (void)update; observed = id; return 17;
}
static uint64_t record_input(void *controller, uint32_t id) {
    (void)controller; observed = id; return 43;
}
static uint64_t reply_id(void *object, void *request, void *reply, void *context) {
    (void)object; (void)request; (void)context;
    IPCBuffer *out = reply;
    uint32_t id = 480;
    out->bytes[out->written] = 0x0b;
    memcpy(out->bytes + out->written + 1, &id, 4);
    out->written += 5; out->extent = out->written;
    return 31;
}
static uint64_t no_reply(void *object, void *request, void *reply, void *context) {
    (void)object; (void)request; (void)reply; (void)context; return 37;
}
static int record_callback(void *engine, int pipe, int user, int kind, const void *payload, int size) {
    (void)engine; (void)pipe; (void)user; (void)kind; (void)size;
    uint64_t id; memcpy(&id, payload, 8); observed = (uint32_t)id; return 41;
}

static void write_config(const char *path, const char *json) {
    FILE *file = fopen(path, "w");
    assert(file);
    assert(fputs(json, file) >= 0);
    assert(fclose(file) == 0);
}

int main(void) {
    OFDispatch utils_hook = (OFDispatch)of_identity_hook.replacement;
    uint64_t (*input_hook)(void *, uint32_t) = (void *)of_input_hook.replacement;
    int (*callback_hook)(void *, int, int, int, const void *, int) = (void *)of_stats_hook.replacement;
    dobby_instrument_callback_t environment_hook = (void *)of_overlay_hook.replacement;
    const char *shared = getenv("ONLINEFIX_TEST_CONFIG");
    if (shared) {
        assert(setenv("ONLINEFIX_CONFIG", shared, 1) == 0);
        uint64_t configured = 105600;
        of_start("game", &configured);
        assert(configured == 480 && of_session().game == 105600 && of_session().keep_id);
        OFPatches p = of_session().patches;
        assert(!p.startup_id && !p.overlay_id && !p.input_id && !p.stats_id);
    }
    char config[] = "/tmp/onlinefix-config-XXXXXX";
    int descriptor = mkstemp(config);
    assert(descriptor >= 0);
    close(descriptor);
    assert(setenv("ONLINEFIX_CONFIG", config, 1) == 0);
    write_config(config, "{\"games\":[{\"id\":105600,\"keepRealAppID\":false}]}");
    uint64_t selected = 105600;
    of_start("game", &selected);
    assert(selected == 480 && !of_session().keep_id);
    selected = 413150; of_start("game", &selected);
    assert(selected == 413150 && !of_session().game);
    write_config(config, "{\"games\":[{\"id\":105600,\"keepRealAppID\":true}]}");
    selected = 105600; of_start("game", &selected);
    assert(selected == 480 && of_session().keep_id);
    write_config(config, "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":{\"startupAppID\":false,\"overlayAppID\":false,\"inputAppID\":false,\"statsAppID\":false}},{\"id\":413150,\"keepRealAppID\":false}]}");
    selected = 105600; of_start("game", &selected);
    OFSession disabled = of_session();
    assert(selected == 480 && of_identity(disabled, 480) == 480);
    uint64_t launch_id = 480, overlay_id = 480;
    of_patch_overlay(disabled, &launch_id, &overlay_id);
    assert(overlay_id == 480 && of_patch_input(disabled, 480) == 480);
    unsigned char payload[20] = {0}, output[20] = {0};
    memcpy(payload, &launch_id, 8);
    assert(!of_patch_stats(disabled, 1101, payload, 20, output));
    selected = 413150; of_start("game", &selected);
    OFSession defaults = of_session();
    assert(selected == 480 && defaults.patches.startup_id && defaults.patches.overlay_id &&
           defaults.patches.input_id && defaults.patches.stats_id);
    assert(of_identity(defaults, 480) == 413150 && of_patch_input(defaults, 480) == 413150);
    of_patch_overlay(defaults, &launch_id, &overlay_id);
    assert(overlay_id == 413150 && launch_id == 480);
    assert(of_patch_stats(defaults, 1101, payload, 20, output));
    uint64_t copied_id; memcpy(&copied_id, output, 8); assert(copied_id == 413150);
    memcpy(&copied_id, payload, 8); assert(copied_id == 480);
    assert(of_patch_input(disabled, 480) == 480);
    write_config(config, "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":{\"statsAppID\":false}}]}");
    selected = 105600; of_start("game", &selected);
    assert(of_session().patches.startup_id && !of_session().patches.stats_id);
    assert(!of_session().patches.terraria_server);
    write_config(config, "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":{\"terrariaServerEnvironment\":true}}]}");
    selected = 105600; of_start("game", &selected);
    assert(selected == 480 && of_session().patches.terraria_server);
    write_config(config, "{\"games\":[]}");
    selected = 105600; of_start("game", &selected);
    assert(selected == 105600 && !of_session().game);
    const char *invalid[] = {"not json", "{}", "{\"games\":[{\"id\":105600,\"keepRealAppID\":false}]}trailing", "{\"games\":[{\"id\":105600}]}",
        "{\"games\":[{\"id\":105600.5,\"keepRealAppID\":false}]}",
        "{\"games\":[{\"id\":105600,\"keepRealAppID\":false},{\"id\":105600,\"keepRealAppID\":true}]}",
        "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":null}]}",
        "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":{\"statsAppID\":\"no\"}}]}",
        "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":{\"statsAppID\":null}}]}",
        "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":{\"unknownPatch\":true}}]}",
        "{\"games\":[{\"id\":413150,\"keepRealAppID\":false,\"patches\":{\"terrariaServerEnvironment\":true}}]}",
        "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":{\"statsAppID\":false,\"statsAppID\":true}}]}"};
    for (size_t i = 0; i < sizeof(invalid)/sizeof(invalid[0]); ++i) {
        write_config(config, invalid[i]);
        selected = 105600; of_start("game", &selected);
        assert(selected == 105600 && !of_session().game);
    }
    unlink(config);
    selected = 105600; of_start("game", &selected);
    assert(selected == 105600);
    unsetenv("ONLINEFIX_CONFIG");
    assert(of_argument("game '-onlinefix'", "-onlinefix"));
    assert(of_argument("game -online\\fix", "-onlinefix"));
    assert(of_argument("game \"-realappid\" -onlinefix", "-realappid"));
    assert(!of_argument("game --onlinefix -onlinefix-more", "-onlinefix"));
    assert(!of_argument("game \"-onlinefix", "-onlinefix"));
    assert(!of_argument(NULL, "-onlinefix"));
    assert(!of_argument("game -onlinefix=1", "-onlinefix"));
    assert(!of_argument("game '-online\\fix'", "-onlinefix"));
    unsigned char code[] = {1,2,3,4,5,6,7,8,1,2,3,4};
    assert(match(code, sizeof(code), "05 ?? 07 08") == code + 4);
    assert(!match(code, sizeof(code), "01 02 03 04"));
    assert(!match(code, sizeof(code), "?? ??"));
    assert(!match(code, sizeof(code), "0G"));
    assert(!match(code, sizeof(code), "0"));
    assert(!match(code, sizeof(code), "0506"));
    assert(!match(code, sizeof(code), "02 03 04"));
    char client_directory[] = "/tmp/onlinefix-client-XXXXXX";
    assert(mkdtemp(client_directory));
    char client[PATH_MAX], package[PATH_MAX], manifest[PATH_MAX];
    snprintf(client, sizeof(client), "%s/steamclient.dylib", client_directory);
    snprintf(package, sizeof(package), "%s/package", client_directory);
    snprintf(manifest, sizeof(manifest), "%s/package/steam_client_osx.manifest", client_directory);
    assert(mkdir(package, 0700) == 0);
    cJSON *profile = cJSON_Parse("{\"steam_build\":1791918634}");
    assert(profile && !client_matches(profile, client));
    const char *invalid_builds[] = {
        "{}", "\"version\" \"1791918635\"", "\"version\" \"1791918634.0\"",
        "\"version\" \"unknown\"", "\"version\" \"1791918634\" \"version\" \"1791918634\"",
        "\"version\" \"1791918634", "\"version\" \"4294967296\""
    };
    for (size_t i = 0; i < sizeof(invalid_builds) / sizeof(invalid_builds[0]); ++i) {
        write_config(manifest, invalid_builds[i]);
        assert(!client_matches(profile, client));
    }
    write_config(manifest, "\"osx\" {\n\t\"version\"\t\"1791918634\"\n}");
    assert(client_matches(profile, client));
    write_config(client, "different client bytes, same build");
    assert(client_matches(profile, client));
    cJSON_SetNumberValue(cJSON_GetObjectItemCaseSensitive(profile, "steam_build"), 1.5);
    assert(!client_matches(profile, client));
    cJSON_SetNumberValue(cJSON_GetObjectItemCaseSensitive(profile, "steam_build"), 1791918634);
    cJSON_DeleteItemFromObjectCaseSensitive(profile, "steam_build");
    assert(!client_matches(profile, client));
    cJSON_Delete(profile);
    assert(unlink(manifest) == 0);
    profile = cJSON_Parse("{\"steam_build\":1791918634}");
    assert(!client_matches(profile, client));
    cJSON_Delete(profile);
    assert(unlink(client) == 0);
    assert(rmdir(package) == 0);
    assert(rmdir(client_directory) == 0);
    uint64_t game = 105600;
    of_start("game -onlinefix", &game);
    assert(game == 480 && of_session().game == 105600);
    assert(of_identity(of_session(), 480) == 105600);
    assert(of_identity(of_session(), 123) == 123);
    of_networking();
    assert(of_identity(of_session(), 480) == 480);
    game = 105600; of_start("game -onlinefix -realappid", &game); of_networking();
    assert(of_identity(of_session(), 480) == 105600);
    game = 105600; of_start("game", &game);
    assert(game == 105600 && !of_session().game);
    game = 0x1000000; of_start("game -onlinefix", &game);
    assert(game == 0x1000000 && !of_session().game);
    game = 105600; of_start("game -onlinefix", &game);
    session_original = record_session;
    of_ready = false;
    assert(session_hook(NULL, 105600, 0) == 17 && observed == 105600);
    of_ready = true;
    assert(session_hook(NULL, 105600, 0) == 17 && observed == 480);
    assert(session_hook(NULL, 999, 0) == 17 && observed == 999);
    unsigned char request[4], response[32] = {0};
    uint32_t method = 0x09607ec4; memcpy(request, &method, 4);
    IPCBuffer in = {.bytes=request, .capacity=4, .written=4, .extent=4};
    IPCBuffer out = {.bytes=response, .capacity=32};
    *of_identity_hook.original = (void *)reply_id; network_original = no_reply;
    assert(utils_hook(NULL, &in, &out, NULL) == 31);
    memcpy(&observed, response+1, 4); assert(observed == 105600);
    assert(network_hook(NULL, &in, NULL, NULL) == 37);
    out.written=out.extent=0;
    utils_hook(NULL, &in, &out, NULL);
    memcpy(&observed, response+1, 4); assert(observed == 480);
    in.error=1; assert(!readable(&in, 4)); in.error=0;
    in.cursor=-1; assert(!readable(&in, 4)); in.cursor=0;
    in.extent=5; assert(!readable(&in, 4)); in.extent=4;
    unsigned char stats[20]={0}; uint64_t id=480; memcpy(stats,&id,8);
    *of_stats_hook.original = (void *)record_callback;
    assert(callback_hook(NULL,1,1,1101,stats,20)==41 && observed==105600);
    memcpy(&id,stats,8); assert(id==480);
    assert(callback_hook(NULL,1,1,999,stats,20)==41 && observed==480);
    // Disabling compatibility patches must leave their actual hooks in passthrough, while core routing remains active.
    write_config(config, "{\"games\":[{\"id\":105600,\"keepRealAppID\":false,\"patches\":{\"startupAppID\":false,\"overlayAppID\":false,\"inputAppID\":false,\"statsAppID\":false}}]}");
    setenv("ONLINEFIX_CONFIG", config, 1);
    game = 105600; of_start("game", &game);
    assert(session_hook(NULL, 105600, 0) == 17 && observed == 480);
    *of_input_hook.original = (void *)record_input;
    assert(input_hook(NULL, 480) == 43 && observed == 480);
    assert(callback_hook(NULL,1,1,1101,stats,20)==41 && observed==480);
    out.written = out.extent = 0;
    assert(utils_hook(NULL, &in, &out, NULL) == 31);
    memcpy(&observed, response+1, 4); assert(observed == 480);
    launch_id = overlay_id = 480;
    DobbyRegisterContext registers = {0};
    registers.general.regs.x1 = (uintptr_t)&launch_id;
    registers.general.regs.x2 = (uintptr_t)&overlay_id;
    environment_hook(NULL, &registers);
    assert(overlay_id == 480);
    unlink(config); unsetenv("ONLINEFIX_CONFIG");
    char *environment[]={"KEEP=value", "DYLD_INSERT_LIBRARIES=/test", "OTHER=1",NULL};
    char **filtered=child_environment(environment);
    assert(filtered && filtered[0]==environment[0] && filtered[1]==environment[2] && !filtered[2]);
    free(filtered); assert(environment[1]);
    assert(steam_target("/a/steam_osx") && !steam_target("/a/steam_osx_helper"));
    of_ready=false; calls=0;
    assert(!of_install("/nonexistent") && !of_ready && calls==0);
    puts("OnlineFix checks passed");
}
