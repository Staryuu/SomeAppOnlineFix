import Foundation

@main struct ManagerChecks {
    static func main() throws {
        precondition(SteamInstaller.processExists(ProcessInfo.processInfo.processIdentifier))
        precondition(!SteamInstaller.processExists(0) && !SteamInstaller.processExists(-1))
        let finished = Process()
        finished.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try finished.run()
        finished.waitUntilExit()
        precondition(!SteamInstaller.processExists(finished.processIdentifier))
        let fm = FileManager.default
        let temporary = fm.temporaryDirectory.appendingPathComponent("OnlineFix-checks-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: temporary) }
        let bundledResources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = temporary.appendingPathComponent("runtime-fixture")
        try fm.copyItem(at: bundledResources, to: resources)
        let picoApp = temporary.appendingPathComponent("PICO PARK 2/pico_park_2.app")
        try fm.createDirectory(at: picoApp, withIntermediateDirectories: true)
        try expectFailure(containing: "missing") { _ = try PicoPark2Patch.isEnabled(app: picoApp) }
        try expectFailure { try PicoPark2Patch.setEnabled(true, app: picoApp) }
        for (id, name, nativeTarget, windowsTarget) in [
            (UInt32(105600), "Terraria", "Terraria.app/Contents/MacOS/TerrariaServer", "Terraria.exe"),
            (UInt32(2644470), "PICO PARK 2", "pico_park_2.app/Contents/Frameworks/GameAssembly.dylib", "pico_park_2.exe")
        ] {
            var candidate = ManagedGame(id: id, name: name)
            precondition(candidate.nativePatchApp == nil)
            let folder = temporary.appendingPathComponent("platform-check/\(name)")
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            candidate.installDirectory = folder
            try Data("MZ Windows executable".utf8).write(to: folder.appendingPathComponent(windowsTarget))
            precondition(candidate.nativePatchApp == nil)
            let target = folder.appendingPathComponent(nativeTarget)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("native patch target fixture".utf8).write(to: target)
            precondition(candidate.nativePatchApp != nil)
            try fm.removeItem(at: target)
            precondition(candidate.nativePatchApp == nil)
        }
        let profileURL = resources.appendingPathComponent("1791918634.json")
        var profile = try JSONSerialization.jsonObject(with: Data(contentsOf: profileURL)) as! [String: Any]
        let clientData = Data("supported Steam client fixture".utf8)
        let sharedFixture = URL(fileURLWithPath: CommandLine.arguments[2])
        let files = ManagerFiles(directory: temporary.appendingPathComponent("settings"))
        try check(files.load().isEmpty)
        let legacy = #"{"games":[{"id":105600,"name":"Terraria","keepRealAppID":false}]}"#
        let old = try JSONDecoder().decode(GameConfiguration.self, from: Data(legacy.utf8))
        precondition(old.games[0].patches == PatchSettings())
        precondition(!old.games[0].patches.terrariaServerEnvironment)
        precondition(!old.games[0].picoPark2Photon)
        precondition(old.games[0].phasmophobiaPhotonAppID.isEmpty)
        let legacyFixJSON = #"{"games":[{"id":2644470,"name":"PICO PARK 2","keepRealAppID":true,"picoPark2Photon":true}]}"#
        try files.save(GameConfiguration(games: []))
        try Data(legacyFixJSON.utf8).write(to: files.config)
        let migrated = try files.loadConfiguration()
        precondition(migrated.games.count == 1 && migrated.games[0].keepRealAppID && !migrated.games[0].hasFileFix)
        precondition(migrated.fixes.count == 1 && migrated.fixes[0].picoPark2Photon && !migrated.fixes[0].keepRealAppID)
        try files.save(migrated)
        try check(files.loadConfiguration() == migrated)
        try expectFailure { try files.save(GameConfiguration(games: [], fixes: migrated.fixes + migrated.fixes)) }
        try expectFailure { try files.save(GameConfiguration(games: [], fixes: [ManagedGame(id: 413150, name: "Unsupported")])) }
        for value in ["null", "false", "{}"] {
            let invalid = "{\"games\":[],\"fixes\":\(value)}"
            try expectFailure { _ = try JSONDecoder().decode(GameConfiguration.self, from: Data(invalid.utf8)) }
        }
        var relocatedPico = ManagedGame(id: 2644470, name: "PICO PARK 2")
        relocatedPico.installDirectory = temporary.appendingPathComponent("relocated-pico")
        let fixRows = migrated.fixGames(in: [relocatedPico, ManagedGame(id: 413150, name: "Unsupported")])
        precondition(fixRows.count == 4 && !fixRows.contains(where: { $0.id == 413150 }))
        let picoRow = fixRows.first(where: { $0.id == 2644470 })!
        precondition(picoRow.picoPark2Photon && picoRow.installDirectory == relocatedPico.installDirectory)
        precondition(migrated.fixGames(in: []).first(where: { $0.id == 2644470 })?.picoPark2Photon == true)
        let catalog = GameConfiguration(games: []).fixGames(in: [])
        precondition(catalog.count == 4 && Set(catalog.map(\.id)).count == 4)
        precondition(catalog.allSatisfy { !$0.fileFixInstalled && !$0.hasFileFix })
        // A remembered install path or leftover empty folder does not mean the game is installed.
        for id: UInt32 in [3241660, 739630] {
            var missing = ManagedGame(id: id, name: "Uninstalled game")
            missing.installDirectory = temporary.appendingPathComponent("uninstalled-\(id)")
            let configuration = GameConfiguration(games: [], fixes: [missing])
            precondition(!configuration.fixGames(in: []).first(where: { $0.id == id })!.fileFixInstalled)
            try fm.createDirectory(at: missing.installDirectory!, withIntermediateDirectories: true)
            precondition(!configuration.fixGames(in: [missing]).first(where: { $0.id == id })!.fileFixInstalled)
        }
        precondition(old.games[0].repoPhoton.isEmpty)
        let repoIDs = RepoPhotonIDs(realtime: "12345678-1234-4321-abcd-123456789abc", voice: "87654321-4321-4321-abcd-cba987654321")
        precondition(repoIDs.isValid)
        for invalid in [RepoPhotonIDs(voice: repoIDs.voice), RepoPhotonIDs(realtime: "bad", voice: repoIDs.voice),
                        RepoPhotonIDs(realtime: repoIDs.realtime, voice: repoIDs.realtime.uppercased()),
                        RepoPhotonIDs(realtime: "99515094-45b7-4c98-ab70-a448c548c83d", voice: repoIDs.voice),
                        RepoPhotonIDs(realtime: repoIDs.realtime, voice: "dfc40a01-c3a4-4395-9707-b71118816d2b".uppercased())] {
            precondition(!invalid.isValid)
        }
        var repo = ManagedGame(id: 3241660, name: "R.E.P.O.")
        repo.installDirectory = temporary.appendingPathComponent("repo-install-check")
        precondition(!repo.fileFixInstalled)
        let repoAssembly = repo.installDirectory!.appendingPathComponent("REPO_Data/Managed/Assembly-CSharp.dll")
        try fm.createDirectory(at: repoAssembly.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("unsupported build".utf8).write(to: repoAssembly)
        precondition(repo.fileFixInstalled && repo.nativePatchApp == nil)
        try expectFailure(containing: "hashes or structure") { _ = try RepoPatch.appIDs(directory: repo.installDirectory!) }
        repo.repoPhoton = repoIDs
        try files.save(GameConfiguration(games: [repo]))
        try check(files.loadConfiguration().fixes == [repo.fileFixSettings])
        try check(files.load()[0].repoPhoton.isEmpty)
        var wrongRepo = ManagedGame(id: 105600, name: "Wrong game")
        wrongRepo.repoPhoton = repoIDs
        try expectFailure { try files.save(GameConfiguration(games: [], fixes: [wrongRepo])) }
        for value in ["null", "true", "{}", "{\"realtime\":1,\"voice\":false}"] {
            let json = "{\"id\":3241660,\"name\":\"R.E.P.O.\",\"keepRealAppID\":false,\"repoPhoton\":\(value)}"
            try expectFailure { _ = try JSONDecoder().decode(ManagedGame.self, from: Data(json.utf8)) }
        }
        precondition(Set(PhotonServers.voiceServers.map(\.appID)).count == PhotonServers.voiceServers.count)
        for server in PhotonServers.voiceServers where !server.appID.isEmpty {
            for pun in PhotonServers.all {
                precondition(RepoPhotonIDs(realtime: pun.appID, voice: server.appID).isValid)
            }
        }
        let punOnly = RepoPhotonIDs(realtime: repoIDs.realtime)
        precondition(punOnly.isValid)
        repo.repoPhoton = punOnly
        try files.save(GameConfiguration(games: [], fixes: [repo]))
        try check(files.loadConfiguration().fixes[0].repoPhoton == punOnly)
        try files.save(GameConfiguration(games: []))
        var phasmInstall = ManagedGame(id: 739630, name: "Phasmophobia")
        phasmInstall.installDirectory = temporary.appendingPathComponent("phasm-install-check")
        precondition(!phasmInstall.fileFixInstalled)
        for path in ["GameAssembly.dll", "Phasmophobia_Data/resources.assets", "Phasmophobia_Data/il2cpp_data/Metadata/global-metadata.dat"] {
            let target = phasmInstall.installDirectory!.appendingPathComponent(path)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("fixture".utf8).write(to: target)
        }
        precondition(phasmInstall.fileFixInstalled)
        try expectFailure(containing: "hashes or structure") { _ = try PhasmophobiaPatch.appID(directory: phasmInstall.installDirectory!) }
        try fm.removeItem(at: phasmInstall.installDirectory!.appendingPathComponent("GameAssembly.dll"))
        precondition(!phasmInstall.fileFixInstalled)
        var phasm = ManagedGame(id: 739630, name: "Phasmophobia")
        precondition(Set(PhotonServers.all.map(\.appID)).count == PhotonServers.all.count)
        for server in PhotonServers.all {
            precondition(PhasmophobiaPatch.validateAppID(server.appID))
            precondition(RepoPhotonIDs(realtime: server.appID).isValid)
            phasm.phasmophobiaPhotonAppID = server.appID
            try files.save(GameConfiguration(games: [], fixes: [phasm]))
            try check(files.loadConfiguration().fixes == [phasm.fileFixSettings])
        }
        phasm.phasmophobiaPhotonAppID = "12345678-1234-4321-abcd-123456789abc"
        try files.save(GameConfiguration(games: [], fixes: [phasm]))
        try check(files.loadConfiguration().fixes == [phasm.fileFixSettings])
        for value in ["bad", "80449c66-0a91-49a5-acb6-ca805e84e605", "80449C66-0A91-49A5-ACB6-CA805E84E605"] {
            phasm.phasmophobiaPhotonAppID = value
            try expectFailure { try files.save(GameConfiguration(games: [], fixes: [phasm])) }
        }
        phasm = ManagedGame(id: 105600, name: "Wrong game")
        phasm.phasmophobiaPhotonAppID = "12345678-1234-4321-abcd-123456789abc"
        try expectFailure { try files.save(GameConfiguration(games: [], fixes: [phasm])) }
        for value in ["null", "true", "123"] {
            let json = "{\"id\":739630,\"name\":\"Phasmophobia\",\"keepRealAppID\":false,\"phasmophobiaPhotonAppID\":\(value)}"
            try expectFailure { _ = try JSONDecoder().decode(ManagedGame.self, from: Data(json.utf8)) }
        }
        try expectFailure { _ = try PhasmophobiaPatch.appID(directory: temporary) }
        try expectFailure { try PhasmophobiaPatch.setAppID("bad", directory: temporary) }
        for value in ["null", "\"yes\""] {
            let invalidPico = "{\"id\":2644470,\"name\":\"PICO PARK 2\",\"keepRealAppID\":false,\"picoPark2Photon\":\(value)}"
            try expectFailure { _ = try JSONDecoder().decode(ManagedGame.self, from: Data(invalidPico.utf8)) }
        }
        let partial = try JSONDecoder().decode(PatchSettings.self, from: Data(#"{"statsAppID":false}"#.utf8))
        precondition(partial.startupAppID && partial.overlayAppID && partial.inputAppID && !partial.statsAppID)
        for json in [#"{"statsAppID":"no"}"#, #"{"statsAppID":null}"#, #"{"unknownPatch":true}"#] {
            try expectFailure { _ = try JSONDecoder().decode(PatchSettings.self, from: Data(json.utf8)) }
        }
        try files.save(GameConfiguration(games: []))
        var game = ManagedGame(id: 105600, name: "Terraria", keepRealAppID: true)
        game.patches = PatchSettings(startupAppID: false, overlayAppID: false, inputAppID: false, statsAppID: false)
        try files.save([game])
        var terraria = game
        terraria.patches.terrariaServerEnvironment = true
        try files.save([terraria])
        try check(files.load() == [game])
        try check(files.loadConfiguration().fixes == [terraria.fileFixSettings])
        var unsupported = ManagedGame(id: 413150, name: "Stardew Valley")
        unsupported.patches.terrariaServerEnvironment = true
        try expectFailure { try files.save([unsupported]) }
        unsupported.patches.terrariaServerEnvironment = false
        unsupported.picoPark2Photon = true
        try expectFailure { try files.save([unsupported]) }
        var pico = ManagedGame(id: 2644470, name: "PICO PARK 2")
        pico.picoPark2Photon = true
        try files.save([pico])
        try check(files.load() == [pico.steamSettings])
        try files.save([game])
        try check(files.load() == [game])
        let other = ManagedGame(id: 413150, name: "Stardew Valley")
        try files.save([game, other])
        let perGame = try files.load()
        precondition(perGame[0].patches == game.patches && perGame[1].patches == PatchSettings())
        // A file fix alone must never opt its game into Steam routing.
        phasm = ManagedGame(id: 739630, name: "Phasmophobia")
        phasm.phasmophobiaPhotonAppID = repoIDs.realtime
        try files.save(GameConfiguration(games: [], fixes: [phasm]))
        try check(files.load().isEmpty)
        try files.save([game])
        try check(files.loadConfiguration().fixes == [phasm.fileFixSettings])
        try files.save([])
        try check(files.load().isEmpty && files.loadConfiguration().fixes == [phasm.fileFixSettings])
        try files.save([game])
        try Data(contentsOf: files.config).write(to: sharedFixture, options: .atomic)
        try expectFailure { try files.save([game, game]) }
        try expectFailure { try files.save([ManagedGame(id: 480, name: "Spacewar")]) }
        try check(files.load() == [game])
        try Data("not json".utf8).write(to: files.config)
        try expectFailure { _ = try files.load() }
        try expectFailure { try files.save([game]) } // Preserve an unreadable fix list.
        try files.save(GameConfiguration(games: [game]))

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
        let client = root.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib")
        try expectFailure { try installer.install(steamRoot: root) }
        try fm.createDirectory(at: client.deletingLastPathComponent(), withIntermediateDirectories: true)
        try clientData.write(to: client)
        // A client without build metadata must not be installed.
        try expectFailure { try installer.install(steamRoot: root) }
        let buildManifest = client.deletingLastPathComponent().appendingPathComponent("package/steam_client_osx.manifest")
        try fm.createDirectory(at: buildManifest.deletingLastPathComponent(), withIntermediateDirectories: true)
        for invalidVersion in [#""version" "1791918635""#, #""version" "1791918634.0""#,
                               #""version" "1791918634" "version" "1791918634""#, #""version" "unknown""#, "{}"] {
            try Data(invalidVersion.utf8).write(to: buildManifest)
            try expectFailure { try installer.install(steamRoot: root) }
        }
        precondition(!fm.fileExists(atPath: files.directory.appendingPathComponent("backup").path))
        precondition(!fm.fileExists(atPath: files.directory.appendingPathComponent("installation.json").path))
        try check(Data(contentsOf: plist) == originalInfo)
        try Data(#""osx" { "version" "1791918634" }"#.utf8).write(to: buildManifest)
        profile.removeValue(forKey: "steam_build")
        try JSONSerialization.data(withJSONObject: profile).write(to: profileURL)
        try expectFailure { try installer.install(steamRoot: root) }
        profile["steam_build"] = 1791918634
        try JSONSerialization.data(withJSONObject: profile).write(to: profileURL)
        try check(installer.verifyClient(steamRoot: root) == 1791918634)
        profile["steam_build"] = 1788652215
        try JSONSerialization.data(withJSONObject: profile).write(to: profileURL)
        try expectFailure { try installer.install(steamRoot: root) }
        profile["steam_build"] = 1791918634
        try JSONSerialization.data(withJSONObject: profile).write(to: profileURL)
        // Different client bytes with the same build are accepted; runtime signatures check compatibility.
        try Data("another laptop's client bytes".utf8).write(to: client)
        try installer.install(steamRoot: root)
        precondition(installer.isInstalled())
        let modified = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as! [String: Any]
        let environment = modified["LSEnvironment"] as! [String: String]
        precondition(environment["EXISTING_SETTING"] == "preserved")
        precondition(environment["DYLD_INSERT_LIBRARIES"] == "/tmp/existing.dylib:" + files.runtime.appendingPathComponent("onlinefix.dylib").path)
        precondition(environment["ONLINEFIX_CONFIG"] == files.config.path)
        precondition(environment["ONLINEFIX_SIG"] == files.runtime.path)
        try expectFailure { try installer.install(steamRoot: root) }
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

        try Data(#""osx" { "version" "1788652215" }"#.utf8).write(to: buildManifest)
        try expectFailure { try installer.install(steamRoot: root) }
        precondition(!installer.isInstalled())
        precondition(!fm.fileExists(atPath: resources.appendingPathComponent("1788652215.json").path))
        try Data(#""osx" { "version" "1791918634" }"#.utf8).write(to: buildManifest)

        let installedLauncher = root.appendingPathComponent("steamapps/common/Terraria/Terraria.app/Contents/MacOS/TerrariaServer")
        let installedLauncherBackup = URL(fileURLWithPath: installedLauncher.path + ".onlinefix-backup")
        try fm.createDirectory(at: installedLauncher.deletingLastPathComponent(), withIntermediateDirectories: true)
        try originalLauncher.write(to: installedLauncher)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedLauncher.path)
        try TerrariaServerPatch.setEnabled(true, launcher: installedLauncher)
        var patchedGame = game
        patchedGame.patches.terrariaServerEnvironment = true
        let picoManifest = #""AppState" { "appid" "2644470" "name" "PICO PARK 2" "installdir" "PICO PARK 2" }"#
        try Data(picoManifest.utf8).write(to: root.appendingPathComponent("steamapps/appmanifest_2644470.acf"))
        let installedPicoApp = root.appendingPathComponent("steamapps/common/PICO PARK 2/pico_park_2.app")
        try fm.createDirectory(at: installedPicoApp, withIntermediateDirectories: true)
        try files.save(GameConfiguration(games: [patchedGame, pico]))
        // A selected full client bundle must be checked instead of the fallback library.
        let bundledClient = app.appendingPathComponent("Contents/MacOS/steamclient.dylib")
        try Data("unsupported bundled client".utf8).write(to: bundledClient)
        try expectFailure { try installer.install(steamRoot: root) }
        try fm.removeItem(at: bundledClient)
        try installer.install(steamRoot: root)
        try expectFailure { try installer.uninstall(steamRoot: temporary.appendingPathComponent("Disconnected library")) }
        precondition(installer.isInstalled())
        try Data((String(decoding: patchedLauncher, as: UTF8.self) + "# changed\n").utf8).write(to: installedLauncher)
        try expectFailure { try installer.uninstall(steamRoot: root) }
        precondition(installer.isInstalled())
        try check(files.loadConfiguration() == GameConfiguration(games: [patchedGame, pico]).separatedFileFixes)
        precondition(fm.fileExists(atPath: installedLauncherBackup.path))
        try patchedLauncher.write(to: installedLauncher)
        try expectFailure { try installer.uninstall(steamRoot: root) }
        precondition(installer.isInstalled())
        try check(files.loadConfiguration() == GameConfiguration(games: [patchedGame, pico]).separatedFileFixes)
        try check(Data(contentsOf: installedLauncher) == patchedLauncher)
        pico.picoPark2Photon = false
        try files.save(GameConfiguration(games: [patchedGame, pico]))
        var missingPhasm = ManagedGame(id: 739630, name: "Phasmophobia")
        missingPhasm.phasmophobiaPhotonAppID = "12345678-1234-4321-abcd-123456789abc"
        missingPhasm.installDirectory = temporary.appendingPathComponent("missing-phasmophobia")
        try files.save(GameConfiguration(games: [patchedGame, pico, missingPhasm]))
        try expectFailure { try installer.uninstall(steamRoot: root) }
        precondition(installer.isInstalled())
        try check(files.loadConfiguration() == GameConfiguration(games: [patchedGame, pico, missingPhasm]).separatedFileFixes)
        try check(Data(contentsOf: installedLauncher) == patchedLauncher)
        var missingRepo = ManagedGame(id: 3241660, name: "R.E.P.O.")
        missingRepo.repoPhoton = repoIDs
        missingRepo.installDirectory = temporary.appendingPathComponent("missing-repo")
        try files.save(GameConfiguration(games: [patchedGame, pico, missingRepo]))
        try expectFailure { try installer.uninstall(steamRoot: root) }
        precondition(installer.isInstalled())
        try check(files.loadConfiguration() == GameConfiguration(games: [patchedGame, pico, missingRepo]).separatedFileFixes)
        try check(Data(contentsOf: installedLauncher) == patchedLauncher)
        try files.save(GameConfiguration(games: [patchedGame, pico]))
        try installer.uninstall(steamRoot: root)
        precondition(!installer.isInstalled())
        try check(Data(contentsOf: installedLauncher) == originalLauncher)
        precondition(!fm.fileExists(atPath: installedLauncherBackup.path))
        pico.picoPark2Photon = false
        try check(files.load() == [game, pico.steamSettings])
        try check(files.loadConfiguration().fixes.allSatisfy { !$0.hasFileFix })
        try check(Data(contentsOf: plist) == originalInfo)
        // Uninstall also restores a fix for a game outside My Games.
        try TerrariaServerPatch.setEnabled(true, launcher: installedLauncher)
        try files.save(GameConfiguration(games: [], fixes: [patchedGame.fileFixSettings]))
        try installer.install(steamRoot: root)
        try installer.uninstall(steamRoot: root)
        try check(files.load().isEmpty)
        try check(Data(contentsOf: installedLauncher) == originalLauncher)
        try check(files.loadConfiguration().fixes == [game.fileFixSettings])
        print("Manager checks passed: legacy fix migration, independent Fix/My Games settings, fix list discovery, library scan, Terraria restoration, PICO/Phasmophobia/REPO validation and REPO configuration, Steam build guard, persistent install, preservation and uninstall rollback.")
    }

    static func check(_ value: @autoclosure () throws -> Bool) throws {
        let passed = try value()
        precondition(passed)
    }

    static func expectFailure(containing message: String? = nil, _ operation: () throws -> Void) throws {
        do { try operation() } catch {
            if let message { precondition(error.localizedDescription.contains(message)) }
            return
        }
        throw ManagerError(message: "Expected the operation to fail.")
    }
}
