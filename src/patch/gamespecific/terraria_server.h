#pragma once
#include <stdbool.h>

// Applied by Manager to the server shell launcher; returns zero or an errno value.
int of_terraria_server_patch(const char *launcher, bool enabled);
