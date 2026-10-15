# OnlineFixMac
Steam OnlineFix for macOS with a native Manager and per-game patches.

# Q & A
- Q: What Supported Steam Version
- A: Curently 1791918634 only

- Q: Does its supported with macsteam
- A: Yes, if your macsteam support steam version 1791918634 (note: install macsteam first)

- Q: What Games Does it support
- A: Im only tested Stardew valey, teraria(use server enviroment patch if cant start server) and other not tested yet because i dont have another device or the windows version cant run in crossover

Note: Keep in mind this Onlinefix still in experiment state

## Build and use

Apple Silicon, macOS 15+. Requires Steam, Xcode Command Line Tools, and CMake.

```bash
make -j4
open out/OnlineFixManager.app
```

The first build downloads Dobby. cJSON is included.

1. Quit Steam → **Installation → Install OnlineFix**.
2. **Add Games** → search by name or AppID → add.
3. Open Steam and launch the game.

No launch options needed. Manager can close after setup.
Remove a game from **My Games** to disable routing on its next launch.

Use compatible game versions and AppID 480 on both sides. Run one game at a time.
Compatibility varies by game
## Game-specific patches

Open **My Games → Patches…** and relaunch after saving.

| Game | Patch | Purpose |
| --- | --- | --- |
| Terraria | Server environment fix | Fixes server startup by clearing inherited Steam injection. |

Game updates may overwrite the patch.

General AppID patches are available for every game. Try **real AppID** if have startup issues.

## Uninstall

Quit Steam → **Installation → Uninstall**.


Settings, backups, and logs:

```text
~/Library/Application Support/OnlineFixManager/
```

**Logs** shows the current Steam session. Copy the log before restarting to keep it.

## Development

- Dylib: `src/`,
- Swift app: `OnlineFixManager/`,
- Tests: `make test`.

### Releases

Open **Actions → Build and release → Run workflow**. Enter the Manager version
(starting at `1.0.0`) and target Steam version. The Manager version must match
`OnlineFixManager/Info.plist` and an entry in [CHANGELOG.md](CHANGELOG.md).

The manual workflow builds, tests, and publishes the Manager ZIP and SHA-256
checksum, creating the `vX.Y.Z` tag for the selected commit if needed.
Target Steam version must match one of the bundled signature profiles' `steam_build`.
All profiles are included and all supported builds are listed in the release notes.


### Game patches

Implementations live in `src/patch/`. Each module owns its hook and original
function pointer. `onlinefix.c` handles core routing and hook registration.

| Patch | Module / setting | How it works |
| --- | --- | --- |
| Keep real AppID | `identity.c` / `keepRealAppID` | Always replaces reported AppID 480 with the real game ID, overriding the startup setting. Matchmaking still uses 480. |
| Restore AppID at startup | `identity.c` / `startupAppID` | Replaces reported AppID 480 with the real game ID until networking starts. |
| Restore overlay AppID | `overlay.c` / `overlayAppID` | Replaces the overlay's AppID 480 with the real game ID in the launch environment. |
| Restore Steam Input AppID | `input.c` / `inputAppID` | Uses the real game ID instead of 480 when checking Steam Input opt-in, so the game's own controller configuration is used. |
| Restore stats callback AppID | `stats.c` / `statsAppID` | Replaces AppID 480 with the real game ID in `UserStatsReceived` callbacks. (Example Terraria wont launch if this disable)|
| Server environment fix (Terraria only) | `terraria_server.c` / `terrariaServerEnvironment` | Adds `unset DYLD_INSERT_LIBRARIES STEAM_DYLD_INSERT_LIBRARIES` to the server launcher to clear inherited Steam injection. Saves a backup and restores it when disabled. |

AppID patches are enabled by default, except **Keep real AppID**.
Change them in **My Games → Patches…**, save, and restart the game.
Manager backs up files changed by a patch and restores them when you disable it or uninstall OnlineFix.

## Credits

- [BetterSteamTools](https://github.com/madoiscool/BetterSteamTools) / [OpenSteamTool](https://github.com/OpenSteam001/OpenSteamTool) — OnlineFix approach.
- [macSteam](https://github.com/Selectively11/macSteam) — Steam hook and ABI reference;
- [Dobby](https://github.com/jmpews/Dobby) — function hooking.
- [cJSON](https://github.com/DaveGamble/cJSON) — configuration parsing.

## License

- OnlineFixManager — [AGPL-3.0](LICENSE).
- Dobby — Apache-2.0; `vendor/dobby/LICENSE` after download.
- cJSON — MIT; included in its source files.
