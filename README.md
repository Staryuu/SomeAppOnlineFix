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

After a Steam update, generate a compatibility profile without AI, Ghidra, or extra Python packages:

```bash
python3 scripts/update-steam-signatures.py
make test
```

The script reads the installed ARM64 client and the newest Steam package manifest.
It uses the highest bundled build as its reference; use `--reference path/to/profile.json`
or `--client path/to/steamclient.dylib` to select another input.
Relative B/BL and ADR/ADRP instructions become `??` wildcards. Every target must
have exactly one aligned match before a new JSON is written; existing profiles are
never overwritten. Structural or ABI changes require manual analysis. Unique byte
matches alone do not establish gameplay compatibility.

## Credits

- [BetterSteamTools](https://github.com/madoiscool/BetterSteamTools) / [OpenSteamTool](https://github.com/OpenSteam001/OpenSteamTool) — OnlineFix approach.
- [macSteam](https://github.com/Selectively11/macSteam) — Steam hook and ABI reference.
- [Dobby](https://github.com/jmpews/Dobby) — function hooking.
- [cJSON](https://github.com/DaveGamble/cJSON) — configuration parsing.

## License

- OnlineFixManager — [AGPL-3.0](LICENSE).
- Dobby — Apache-2.0; `vendor/dobby/LICENSE` after download.
- cJSON — MIT; included in its source files.
