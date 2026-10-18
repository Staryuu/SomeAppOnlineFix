#include "onlinefix.h"
#include <mach-o/dyld.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static FILE *logfile;
void of_log(const char *format, ...) {
    FILE *outputs[] = {stderr, logfile};
    for (size_t i = 0; i < 2; ++i) {
        if (!outputs[i]) continue;
        flockfile(outputs[i]);
        fprintf(outputs[i], "[onlinefix pid=%d] ", getpid());
        va_list args;
        va_start(args, format);
        vfprintf(outputs[i], format, args);
        va_end(args);
        fputc('\n', outputs[i]);
        fflush(outputs[i]);
        funlockfile(outputs[i]);
    }
}

static void *worker(void *unused) {
    (void)unused;
    for (int attempt = 0; attempt < 600; ++attempt) {
        for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
            const char *name = _dyld_get_image_name(i);
            const char *base = name ? strrchr(name, '/') : NULL;
            if (name && !strcmp(base ? base + 1 : name, "steamclient.dylib")) {
                bool ok = of_install(getenv("ONLINEFIX_SIG"));
                of_log("routing %s", ok ? "ready; Manager game list and -onlinefix supported" : "inactive");
                return NULL;
            }
        }
        usleep(100000);
    }
    of_log("steamclient load timeout; rerun scripts/launch.sh after Steam restarts");
    return NULL;
}

#ifndef ONLINEFIX_TEST
__attribute__((constructor)) static void bootstrap(void) {
    if (strcmp(getprogname(), "steam_osx")) return;
    const char *path = getenv("ONLINEFIX_LOG");
    if (path && *path) logfile = fopen(path, "w");
    of_log("Steam launch: new log session");
    if (getenv("ONLINEFIX_DISABLE")) { of_log("disabled by ONLINEFIX_DISABLE"); return; }
    of_filter_children();
    pthread_t thread;
    int error = pthread_create(&thread, NULL, worker, NULL);
    if (error) of_log("cannot start loader: %d", error);
    else pthread_detach(thread);
}
#endif
