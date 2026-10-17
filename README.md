# SomeAppOnlineFix
Still experimental. Intel Mac Not supported

## Disclaimer

This project does not bypass game licensing and still requires a valid, original game license. It is intended for game owners who want to play with people who do not own the game.

## Requirements

- Apple Silicon, macOS 15+
- Xcode Command Line Tools with Swift 6, CMake
- Steam (compatible build)
- Internet access for the first build (Dobby)

## Build

```bash
make -j4
open out/OnlineFixManager.app
```

## Contributing

Issues and PRs are welcome. Keep changes focused and run `make test` before submitting.
For compatibility reports, include the game/AppID, macOS version, Steam build, and relevant logs.
Game-specific patches belong in `src/patch/`.

## Credits

- [BetterSteamTools](https://github.com/madoiscool/BetterSteamTools) / [OpenSteamTool](https://github.com/OpenSteam001/OpenSteamTool) — OnlineFix approach.
- [macSteam](https://github.com/Selectively11/macSteam) — Steam hook and ABI reference.
- [Dobby](https://github.com/jmpews/Dobby) — function hooking.
- [cJSON](https://github.com/DaveGamble/cJSON) — configuration parsing.

## License

- OnlineFixManager — [AGPL-3.0](LICENSE).
- Dobby — Apache-2.0; `vendor/dobby/LICENSE` after download.
- cJSON — MIT; included in its source files.
