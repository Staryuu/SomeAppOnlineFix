#pragma once
#include <stdbool.h>

// Patch or check the supported macOS build. Returns 0 or errno.
int of_pico_park_2_patch(const char *app, bool enabled);
int of_pico_park_2_status(const char *app, bool *enabled);
