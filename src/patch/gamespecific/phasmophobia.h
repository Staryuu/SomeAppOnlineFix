#pragma once
#include <stdbool.h>

// Exact supported Windows build; caller supplies a Photon AppID. Server acceptance is separate.
// Disable accepts NULL AppID and restores the original files; returns zero or errno.
// Backups are siblings of the game directory; validated older in-game backups remain restorable.
int of_phasmophobia_patch(const char *game_directory, const char *photon_app_id, bool enabled);

// Empty AppID means original files; partial/unknown states return an error.
int of_phasmophobia_status(const char *game_directory, char photon_app_id[37]);
