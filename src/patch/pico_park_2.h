#pragma once
#include <stdbool.h>

// Manager applies or verifies the supported Mac build; returns zero or an errno value.
int of_pico_park_2_patch(const char *app, bool enabled);
int of_pico_park_2_status(const char *app, bool *enabled);
