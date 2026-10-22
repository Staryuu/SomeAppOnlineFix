# SomeAppOnlineFix

Experimental OnlineFix implementation for macOS on Apple Silicon.

> [!WARNING]
> **This project is still experimental.** Bugs and compatibility issues are expected.
>
> **Intel-based Macs are not supported.** Apple Silicon (M1 or newer) and macOS 15+ are required.
## Disclaimer

> [!IMPORTANT]
> This project does not bypass game licensing and still requires a valid, original game license.
>
> It is intended for game owners who want to play with people who do not own the game.

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

Issues and pull requests are welcome!

- Keep changes focused and relevant.
- Run `make test` before submitting a PR.
- For compatibility reports, please include:
  - Game name and AppID
  - macOS version
  - Steam build/version
  - Relevant logs
- Place game-specific patches in `src/patch/`.

## Credits

- [BetterSteamTools](https://github.com/madoiscool/BetterSteamTools) / [OpenSteamTool](https://github.com/OpenSteam001/OpenSteamTool) — OnlineFix approach.
- [macSteam](https://github.com/Selectively11/macSteam) — Steam hook reference.

## License

- OnlineFixManager — [AGPL-3.0](LICENSE).
- Third-party components are subject to their respective licenses. See the license notices included in their source code or directories.
