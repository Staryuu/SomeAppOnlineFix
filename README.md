# OnlineFixMac
Steam OnlineFix for macOS with a native Manager and per-game patches.

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
Target Steam version is recorded in the release description; it does not change
the bundled signature profile. Builds use ad-hoc signing and are not notarized.

### Game patches

Implementations live in `src/patch/`. Each module owns its hook and original
function pointer. `onlinefix.c` handles core routing and hook registration.

| Module | Per-game setting |
| --- | --- |
| `identity.c` | `startupAppID` |
| `overlay.c` | `overlayAppID` |
| `input.c` | `inputAppID` |
| `stats.c` | `statsAppID` |
| `terraria_server.c` | `terrariaServerEnvironment` (Terraria only) |

AppID patches default to on;
Settings live in each game's `patches` object in `games.json`.

For a new patch, add its implementation here, guard it with `OFSession.game`,
and register its `OFHook` in `onlinefix.c`. Add its toggle to `patch.h`,
`settings.c`, Swift `PatchSettings`, and the settings sheet. Test on/off behavior
and a different AppID. New `.c` files are built automatically.

Rebuild and reinstall after adding patch code. Toggle changes need a game relaunch.
Manager applies/restores file patches when saving settings or uninstalling.

## Credits

- [BetterSteamTools](https://github.com/madoiscool/BetterSteamTools) / [OpenSteamTool](https://github.com/OpenSteam001/OpenSteamTool) — OnlineFix approach.
- [macSteam](https://github.com/Selectively11/macSteam) — Steam hook and ABI reference;
- [Dobby](https://github.com/jmpews/Dobby) — function hooking.
- [cJSON](https://github.com/DaveGamble/cJSON) — configuration parsing.

## License

- OnlineFixManager — [AGPL-3.0](LICENSE).
- Dobby — Apache-2.0; `vendor/dobby/LICENSE` after download.
- cJSON — MIT; included in its source files.
