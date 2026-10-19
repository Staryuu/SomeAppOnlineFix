#pragma once
#include <stdbool.h>

// Voice is optional. IDs must be valid, different and not the original game IDs.
bool of_repo_validate_ids(const char *realtime, const char *voice);
// Patch the supported Windows build. Disable accepts NULL IDs. Returns 0 or errno.
// Backups stay beside the game folder.
int of_repo_patch(const char *directory, const char *realtime, const char *voice, bool enabled);
int of_repo_status(const char *directory, char realtime[37], char voice[37]);
