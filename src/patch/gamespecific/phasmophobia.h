#pragma once
#include <stdbool.h>

// Change the Photon App ID and auth mode for the supported Windows build.
// Disable restores the originals and accepts a NULL App ID. Returns 0 or errno.
// Backups stay beside the game folder. Older in-game backups are also accepted.
int of_phasmophobia_patch(const char *game_directory, const char *photon_app_id, bool enabled);

// An empty ID means original files. Incomplete or unknown patches return an error.
int of_phasmophobia_status(const char *game_directory, char photon_app_id[37]);
