# OnlineFixMac

Experimental OnlineFix for macOS. Routes selected games to Spacewar (AppID 480).
OnlineFix Manager handles installation, game selection, and settings.

## Build and use

Apple Silicon only, macOS 15+. Install Steam and launch it once first.
Requires Xcode Command Line Tools and CMake.

```bash
make -j4
open out/OnlineFixManager.app
```

1. Quit Steam. Open **Installation** and click **Install OnlineFix**.
2. Go to **Add Games**. Search by name or enter the game's AppID.
3. Add the game, then open Steam normally.

No `-onlinefix` launch option is needed. Manager does not need to stay open.
Open **My Games → Patches…** to change compatibility patches for one game.
If the game has startup issues, try **Keep real AppID**. Relaunch after saving.
For Terraria's server-launch failure, enable **Server environment fix** under
**Patches…**. It updates only the server shell launcher and keeps an adjacent
`.onlinefix-backup`. Disabling restores it; game updates may overwrite the patch.
Remove a game from **My Games** and relaunch it to disable automatic routing.

Both players need compatible game versions and matchmaking through AppID 480.
Normal game lobbies are separate. Run only one game at a time.
Full multiplayer remains unverified. Steam updates may require reinstalling
OnlineFix or updating its signatures.

## Uninstall

Disable Terraria's **Server environment fix** first to restore its launcher.
Quit Steam, open **Installation**, and click **Uninstall**.
This restores the backed-up Steam bundle and keeps your game list and logs.
Keep the `backup` folder until you uninstall. If Steam changed after installation,
removal refuses to restore an older bundle.

Settings, backups, and logs are here:

```text
~/Library/Application Support/OnlineFixManager/
```

Check **Logs** or `onlinefix.log` if something fails.
The log resets on each Steam launch. Copy it before restarting if needed.

## Development

Dylib source is in `src/`. Swift app source is in `OnlineFixManager/`.
Run `make test` for the routing and installer checks.

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

The four AppID patches default to on; the Terraria server fix defaults to off.
Manager saves them in each game's `patches` object in
`games.json`. Old configs keep these defaults. **Keep real AppID** overrides
startup-only reporting; matchmaking still uses 480.

For a new patch, add its implementation here, guard it with `OFSession.game`,
and register its `OFHook` in `onlinefix.c`. Add its toggle to `patch.h`,
`settings.c`, Swift `PatchSettings`, and the settings sheet. Test on/off behavior
and a different AppID. New `.c` files are built automatically.

New patch code needs a rebuild and reinstall. Changing existing toggles only
needs a game relaunch.
The Terraria file patch is applied/restored by Manager when saving its toggle.

## License

See [LICENSE](LICENSE) and [NOTICE.md](NOTICE.md) for credits and dependencies.
