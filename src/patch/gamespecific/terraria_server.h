#pragma once
#include <stdbool.h>

// Remove Steam injection from the server launcher. Returns 0 or errno.
int of_terraria_server_patch(const char *launcher, bool enabled);
