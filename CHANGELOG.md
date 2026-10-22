# Changelog

## v2.0.0

- CustomFix workflow for installing and managing game-specific fixes directly in Manager.
- Built-in Fix catalog organizing patch sources and supported games.
- Native Photon multiplayer compatibility patches for PICO PARK 2, R.E.P.O., and Phasmophobia.
- Custom Photon server configuration support via local settings and secrets.
- Dynamic Steam client build detection with versioned compatibility profile loading.
- Steam signature update script to generate profiles after Steam client updates.
- Manifest validation and version matching enforcement during installation.
- Refined child process filtering to avoid overlapping hooks with NotProton.

## v1.0.0

Initial release for Apple Silicon, macOS 15+.

- Native Manager with Steam game search, artwork, and per-game settings.
- Standalone OnlineFix dylib routing selected games to AppID 480.
- Persistent installation with Steam backup and guarded restoration.
- Separate compatibility patches for startup, overlay, Steam Input, and stats.
- Terraria server environment fix with automatic restoration on uninstall.
- Logs reset on each Steam launch.

Terraria now can host & play, (multiplayer not tested yet)
