#include "onlinefix.h"
#include <dobby.h>
#include "ipc.h"


_Atomic bool of_ready;
static uint32_t (*session_original)(void *, uint32_t, uint8_t);
static OFDispatch network_original;
void of_networking(void);

static void launch_hook(void *pc, DobbyRegisterContext *registers) {
    (void)pc;
    if (of_ready) of_start((const char *)registers->general.regs.x2,
                          (uint64_t *)registers->general.regs.x4);
}

static uint32_t session_hook(void *engine, uint32_t game, uint8_t update) {
    OFSession s = of_session();
    if (of_ready && s.game && game == s.game) {
        of_log("pipe AppID: %u -> 480", game);
        game = 480;
    }
    return session_original(engine, game, update);
}

static uint64_t network_hook(void *object, void *request, void *reply, void *context) {
    if (of_ready && readable(request, 4)) of_networking();
    return network_original(object, request, reply, context);
}

static OFHook launch = {"CUser::SpawnProcess", (void *)launch_hook, NULL};
static OFHook session = {"CSteamEngine::SetAppIDForCurrentPipe", (void *)session_hook, (void **)&session_original};
static OFHook network = {"IClientNetworkingSocketsSerialized::__ipc_server_dispatch", (void *)network_hook, (void **)&network_original};

static OFHook *targets[] = {
    &launch, &of_overlay_hook, &of_input_hook, &session,
    &of_identity_hook, &network, &of_stats_hook,
};

bool of_resolve(const char *profile, const char *const *names, void **addresses, size_t count);

bool of_install(const char *profile) {
    const size_t count = sizeof(targets) / sizeof(targets[0]);
    const char *names[count];
    void *addresses[count];
    for (size_t i = 0; i < count; ++i) names[i] = targets[i]->name;
    if (!of_resolve(profile, names, addresses, count)) return false;
    for (size_t i = 0; i < count; ++i) {
        OFHook h = *targets[i];
        int result = h.original ? DobbyHook(addresses[i], h.replacement, h.original)
            : DobbyInstrument(addresses[i], (dobby_instrument_callback_t)h.replacement);
        of_log("hook %s @ %p: %d", h.name, addresses[i], result);
        if (result) {
            of_log("installation incomplete; installed hooks stay in passthrough mode");
            return false;
        }
    }
    of_ready = true;
    return true;
}
