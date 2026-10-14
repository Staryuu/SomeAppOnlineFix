import Foundation

@main struct ManagerChecks {
    static func main() throws {
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("OnlineFix-checks-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let sharedFixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let files = ManagerFiles(directory: temporary.appendingPathComponent("settings"))
        try check(files.load().isEmpty)
        let legacy = #"{"games":[{"id":105600,"name":"Terraria","keepRealAppID":false}]}"#
        let old = try JSONDecoder().decode(GameConfiguration.self, from: Data(legacy.utf8))
        precondition(old.games[0].patches == PatchSettings())
        precondition(!old.games[0].patches.terrariaServerEnvironment)
        let partial = try JSONDecoder().decode(PatchSettings.self, from: Data(#"{"statsAppID":false}"#.utf8))
        precondition(partial.startupAppID && partial.overlayAppID && partial.inputAppID && !partial.statsAppID)
        for json in [#"{"statsAppID":"no"}"#, #"{"statsAppID":null}"#, #"{"unknownPatch":true}"#] {
            try expectFailure { _ = try JSONDecoder().decode(PatchSettings.self, from: Data(json.utf8)) }
        }
        var game = ManagedGame(id: 105600, name: "Terraria", keepRealAppID: true)
        game.patches = PatchSettings(startupAppID: false, overlayAppID: false, inputAppID: false, statsAppID: false)
        try files.save([game])
        var terraria = game
        terraria.patches.terrariaServerEnvironment = true
        try files.save([terraria])
        try check(files.load() == [terraria])
        var unsupported = ManagedGame(id: 413150, name: "Stardew Valley")
        unsupported.patches.terrariaServerEnvironment = true
        try expectFailure { try files.save([unsupported]) }
        try files.save([game])
        try check(files.load() == [game])
        let other = ManagedGame(id: 413150, name: "Stardew Valley")
        try files.save([game, other])
        let perGame = try files.load()
        precondition(perGame[0].patches == game.patches && perGame[1].patches == PatchSettings())
        try files.save([game])
        try Data(contentsOf: files.config).write(to: sharedFixture, options: .atomic)
        try expectFailure { try files.save([game, game]) }
        try expectFailure { try files.save([ManagedGame(id: 480, name: "Spacewar")]) }
        try check(files.load() == [game])
        try Data("not json".utf8).write(to: files.config)
        try expectFailure { _ = try files.load() }
        try files.save([game])

        let root = temporary.appendingPathComponent("Steam library")
        let external = temporary.appendingPathComponent("External library")
        try fm.createDirectory(at: root.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        try fm.createDirectory(at: external.appendingPathComponent("steamapps"), withIntermediateDirectories: true)
        let manifest = #""AppState" { "appid" "105600" "name" "Terraria" "installdir" "Terraria" }"#
        try Data(manifest.utf8).write(to: root.appendingPathComponent("steamapps/appmanifest_105600.acf"))
        let second = #""AppState" { "appid" "413150" "name" "Stardew Valley" }"#
        try Data(second.utf8).write(to: external.appendingPathComponent("steamapps/appmanifest_413150.acf"))
        let folders = "\"libraryfolders\" { \"0\" { \"path\" \"\(root.path)\" } \"1\" { \"path\" \"\(external.path)\" } }"
        try Data(folders.utf8).write(to: root.appendingPathComponent("steamapps/libraryfolders.vdf"))
        let library = try SteamLibrary.scan(root: root)
        precondition(Set(library.map(\.id)) == [105600, 413150])
        precondition(library.first(where: { $0.id == 413150 })?.name == "Stardew Valley")
        precondition(library.first(where: { $0.id == 105600 })?.installDirectory?.lastPathComponent == "Terraria")
        let quoted = SteamLibrary.pairs(#""name" "Game \"Deluxe\"" "path" "/Games/with\\slash""#)
        precondition(quoted[0].1 == "Game \"Deluxe\"" && quoted[1].1 == "/Games/with\\slash")
        let searchJSON = #"{"items":[{"id":105600,"type":"app","name":"Terraria","tiny_image":"https://shared.fastly.steamstatic.com/test.jpg"},{"id":55,"type":"bundle","name":"Bundle"},{"id":480,"type":"app","name":"Spacewar"},{"id":105600,"type":"app","name":"Duplicate"}]}"#
        let results = try SteamStore.decode(Data(searchJSON.utf8))
        precondition(results.count == 1 && results[0].id == 105600 && results[0].artworkURL.scheme == "https")
        let request = SteamStore.request(for: "Game & More 日本語")
        let components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        precondition(components.queryItems?.first(where: { $0.name == "term" })?.value == "Game & More 日本語")
        precondition(components.host == "store.steampowered.com")
        try expectFailure { _ = try SteamStore.decode(Data("not json".utf8)) }

        let launcher = temporary.appendingPathComponent("TerrariaServer")
        let launcherBackup = URL(fileURLWithPath: launcher.path + ".onlinefix-backup")
        let launcherText = """
        #!/bin/bash
        # MonoKickstart Shell Script
        cd "$(dirname "$0")"
        UNAME=$(uname)
        ARCH=$(uname -m)
        if [ "$UNAME" = Darwin ]; then
            if [ -n "$STEAM_DYLD_INSERT_LIBRARIES" ] && [ -z "$DYLD_INSERT_LIBRARIES" ]; then
                export DYLD_INSERT_LIBRARIES="$STEAM_DYLD_INSERT_LIBRARIES"
            fi
            ./TerrariaServer.bin.osx "$@"
        fi

        """
        let originalLauncher = Data(launcherText.utf8)
        try originalLauncher.write(to: launcher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        try TerrariaServerPatch.setEnabled(true, launcher: launcher)
        let patchedLauncher = try Data(contentsOf: launcher)
        precondition(patchedLauncher != originalLauncher)
        try check(Data(contentsOf: launcherBackup) == originalLauncher)
        try check((fm.attributesOfItem(atPath: launcher.path)[.posixPermissions] as? Int) == 0o755)
        try TerrariaServerPatch.setEnabled(true, launcher: launcher)
        try check(Data(contentsOf: launcher) == patchedLauncher)
        let serverStub = temporary.appendingPathComponent("TerrariaServer.bin.osx")
        try Data("#!/bin/bash\n[[ -z ${DYLD_INSERT_LIBRARIES:-} && -z ${STEAM_DYLD_INSERT_LIBRARIES:-} && $SteamAppId == 480 ]] || exit 9\nprintf 'server stub reached'\n".utf8).write(to: serverStub)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: serverStub.path)
        // Set contamination inside a running shell, so the test itself doesn't inject a library or crash OS tools.
        try SteamInstaller.run("/bin/bash", ["-c", "export DYLD_INSERT_LIBRARIES=/invalid/steamloader.dylib; export STEAM_DYLD_INSERT_LIBRARIES=/invalid/steamloader.dylib; export SteamAppId=480; . \"$0\"", launcher.path])
        try TerrariaServerPatch.setEnabled(false, launcher: launcher)
        try check(Data(contentsOf: launcher) == originalLauncher)
        precondition(!fm.fileExists(atPath: launcherBackup.path))
        try TerrariaServerPatch.setEnabled(false, launcher: launcher)
        try TerrariaServerPatch.setEnabled(true, launcher: launcher)
        try Data((String(decoding: patchedLauncher, as: UTF8.self) + "# Steam update\n").utf8).write(to: launcher)
        try expectFailure { try TerrariaServerPatch.setEnabled(false, launcher: launcher) }
        precondition(fm.fileExists(atPath: launcherBackup.path))
        try patchedLauncher.write(to: launcher)
        try TerrariaServerPatch.setEnabled(false, launcher: launcher)
        let otherLauncher = temporary.appendingPathComponent("OtherGame")
        try originalLauncher.write(to: otherLauncher)
        try expectFailure { try TerrariaServerPatch.setEnabled(true, launcher: otherLauncher) }
        try Data("#!/bin/bash\necho unsupported\n".utf8).write(to: launcher)
        try expectFailure { try TerrariaServerPatch.setEnabled(true, launcher: launcher) }
        try fm.removeItem(at: launcher)
        try fm.createSymbolicLink(at: launcher, withDestinationURL: otherLauncher)
        try expectFailure { try TerrariaServerPatch.setEnabled(true, launcher: launcher) }

        let app = temporary.appendingPathComponent("Steam.app")
        try fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try fm.createDirectory(at: app.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "com.valvesoftware.steam", "CFBundleExecutable": "steam_osx",
            "CFBundlePackageType": "APPL", "CFBundleVersion": "1",
            "LSEnvironment": ["DYLD_INSERT_LIBRARIES": "/tmp/existing.dylib", "EXISTING_SETTING": "preserved"]]
        let plist = app.appendingPathComponent("Contents/Info.plist")
        let originalInfo = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try originalInfo.write(to: plist)
        let c = temporary.appendingPathComponent("fixture.c")
        try Data("int main(void) { return 0; }\n".utf8).write(to: c)
        try SteamInstaller.run("/usr/bin/clang", ["-arch", "arm64", c.path, "-o", app.appendingPathComponent("Contents/MacOS/steam_osx").path])
        try SteamInstaller.run("/usr/bin/codesign", ["--force", "--sign", "-", app.path])
        let originalExecutable = try Data(contentsOf: app.appendingPathComponent("Contents/MacOS/steam_osx"))
        var installer = SteamInstaller(app: app, files: files, resources: resources)
        installer.registerWithLaunchServices = false // Never register the fixture as the user's Steam.
        precondition(!installer.isInstalled())
        try installer.install()
        precondition(installer.isInstalled())
        let modified = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        let environment = modified["LSEnvironment"] as! [String: String]
        precondition(environment["EXISTING_SETTING"] == "preserved")
        precondition(environment["DYLD_INSERT_LIBRARIES"] == "/tmp/existing.dylib:" + files.runtime.appendingPathComponent("onlinefix.dylib").path)
        precondition(environment["ONLINEFIX_CONFIG"] == files.config.path)
        try expectFailure { try installer.install() }
        let changed = app.appendingPathComponent("Contents/Resources/update-marker")
        try Data("updated".utf8).write(to: changed)
        try expectFailure { try installer.uninstall() }
        precondition(fm.fileExists(atPath: changed.path))
        try fm.removeItem(at: changed)
        try installer.uninstall()
        precondition(!installer.isInstalled())
        try check(Data(contentsOf: plist) == originalInfo)
        try check(Data(contentsOf: app.appendingPathComponent("Contents/MacOS/steam_osx")) == originalExecutable)
        try check(files.load() == [game])
        try SteamInstaller.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        print("Manager checks passed: config, library scan, Terraria server patch and environment, persistent install, preservation, update guard, uninstall.")
    }

    static func check(_ value: @autoclosure () throws -> Bool) throws {
        let passed = try value()
        precondition(passed)
    }

    static func expectFailure(_ operation: () throws -> Void) throws {
        do { try operation() } catch { return }
        throw ManagerError(message: "Expected the operation to fail.")
    }
}
