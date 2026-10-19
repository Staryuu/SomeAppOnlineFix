import CryptoKit
import Darwin
import Foundation

struct SteamInstaller: Sendable {
    let app: URL
    let files: ManagerFiles
    let resources: URL
    var registerWithLaunchServices = true
    private var backup: URL { files.directory.appendingPathComponent("backup/Steam.app") }
    private var receipt: URL { files.directory.appendingPathComponent("installation.json") }
    private var library: URL { files.runtime.appendingPathComponent("onlinefix.dylib") }
    private var plist: URL { app.appendingPathComponent("Contents/Info.plist") }

    private struct Receipt: Codable {
        let appPath: String
        let originalHash: String
        let installedHash: String
    }

    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    static func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ManagerError(message: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                + "\nCommand failed: \(URL(fileURLWithPath: executable).lastPathComponent)")
        }
    }

    private func info(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.valvesoftware.steam",
              info["CFBundleExecutable"] as? String == "steam_osx" else {
            throw ManagerError(message: "Choose a valid Steam.app bundle.")
        }
        return info
    }

    func isInstalled() -> Bool {
        guard let value = try? info(at: plist), let environment = value["LSEnvironment"] as? [String: String] else { return false }
        return (environment["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").contains(Substring(library.path))
            && FileManager.default.fileExists(atPath: library.path)
    }

    // Hash every file and symlink before restoring a whole bundle, so an updater's changes aren't lost.
    private func fingerprint(_ input: URL) throws -> String {
        let fm = FileManager.default
        var pending: [(URL, String)] = [(input, "")]
        var entries: [(URL, String)] = []
        while let (folder, relative) = pending.popLast() {
            for url in try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) {
                let name = relative + "/" + url.lastPathComponent
                entries.append((url, name))
                let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values.isDirectory == true && values.isSymbolicLink != true { pending.append((url, name)) }
            }
        }
        var hash = SHA256()
        for (url, relative) in entries.sorted(by: { $0.1 < $1.1 }) {
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            hash.update(data: Data((relative + "\0").utf8))
            if values.isSymbolicLink == true {
                hash.update(data: Data(("link:" + (try fm.destinationOfSymbolicLink(atPath: url.path)) + "\0").utf8))
            } else if values.isDirectory == true {
                hash.update(data: Data("directory\0".utf8))
            } else {
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let size = try handle.seekToEnd()
                try handle.seek(toOffset: 0)
                hash.update(data: Data("file:\(size)\0".utf8))
                while let data = try handle.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
            }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func swap(_ other: URL) throws {
        guard renamex_np(app.path, other.path, UInt32(RENAME_SWAP)) == 0 else {
            throw ManagerError(message: "Unable to replace Steam atomically: \(String(cString: strerror(errno))).")
        }
    }

    private func register() throws {
        if !registerWithLaunchServices { return }
        try Self.run("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister", ["-f", app.path])
    }

    private func locked(_ operation: () throws -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let lock = files.directory.appendingPathComponent("installer.lock", isDirectory: true)
        do { try fm.createDirectory(at: lock, withIntermediateDirectories: false) }
        catch { throw ManagerError(message: "Another installation may be running. If it was interrupted, keep the backup and remove installer.lock before retrying.") }
        defer { try? fm.removeItem(at: lock) }
        try operation()
    }

    @discardableResult func verifyClient(steamRoot: URL) throws -> UInt32 {
        struct Profile: Decodable {
            let steam_build: UInt32
        }
        let bundled = app.appendingPathComponent("Contents/MacOS/steamclient.dylib")
        let client = FileManager.default.fileExists(atPath: bundled.path) ? bundled
            : steamRoot.appendingPathComponent("Steam.AppBundle/Steam/Contents/MacOS/steamclient.dylib")
        let manifest = client.deletingLastPathComponent().appendingPathComponent("package/steam_client_osx.manifest")
        guard FileManager.default.isReadableFile(atPath: client.path),
              let data = try? Data(contentsOf: manifest), data.count <= 1024 * 1024,
              let text = String(data: data, encoding: .utf8), !text.contains("\0") else {
            throw ManagerError(message: "Cannot verify the Steam client build. Start Steam once to finish its setup, then quit it and retry.")
        }
        // shortcut: the manifest may be cached; runtime must also validate every signature against the loaded client.
        let versions = SteamLibrary.pairs(text).filter { $0.0 == "version" }
        guard versions.count == 1, let build = UInt32(versions[0].1), build > 0,
              versions[0].1 == String(build) else {
            throw ManagerError(message: "Cannot determine a valid Steam client build. Installation was blocked.")
        }
        let profileURL = resources.appendingPathComponent("\(build).json")
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw ManagerError(message: "Steam build \(build) is not supported by this OnlineFix release. Installation was blocked.")
        }
        let profile = try JSONDecoder().decode(Profile.self, from: Data(contentsOf: profileURL))
        guard profile.steam_build == build else {
            throw ManagerError(message: "The bundled Steam compatibility profile does not match its filename. Rebuild OnlineFix Manager.")
        }
        return build
    }

    func install(steamRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam")) throws {
        try locked {
            let fm = FileManager.default
            guard !fm.fileExists(atPath: receipt.path), !fm.fileExists(atPath: backup.path) else {
                throw ManagerError(message: "An installation or recovery backup already exists. Uninstall OnlineFix before installing another version. Keep the backup if Steam has changed.")
            }
            var properties = try info(at: plist)
            let build = try verifyClient(steamRoot: steamRoot)
            if !fm.fileExists(atPath: files.config.path) { try files.save([]) }
            _ = try files.load()
            guard fm.isWritableFile(atPath: app.path), fm.isWritableFile(atPath: app.deletingLastPathComponent().path),
                  !files.directory.path.hasPrefix(app.path + "/") else {
                throw ManagerError(message: "Steam must be writable by your account. Select a writable Steam.app.")
            }
            try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let source = resources.appendingPathComponent("onlinefix.dylib")
            try Self.run("/usr/bin/lipo", [source.path, "-verify_arch", "arm64"])
            try Self.run("/usr/bin/lipo", [source.path, "-verify_arch", "x86_64"])
            try Self.run("/usr/bin/codesign", ["--verify", "--strict", source.path])
            let originalHash = try fingerprint(app)
            let staging = app.deletingLastPathComponent().appendingPathComponent(".OnlineFix-\(UUID().uuidString).app")
            var exchanged = false
            do {
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Self.run("/usr/bin/ditto", [app.path, backup.path])
                guard try fingerprint(backup) == originalHash else { throw ManagerError(message: "Backup verification failed. Steam was not changed.") }
                if fm.fileExists(atPath: files.runtime.path) { try fm.removeItem(at: files.runtime) }
                try Self.run("/usr/bin/ditto", [resources.path, files.runtime.path])
                try Self.run("/usr/bin/ditto", [app.path, staging.path])
                var environment = properties["LSEnvironment"] as? [String: String] ?? [:]
                var libraries = (environment["DYLD_INSERT_LIBRARIES"] ?? "").split(separator: ":").map(String.init)
                guard !library.path.contains(":") else { throw ManagerError(message: "The OnlineFix path cannot contain a colon.") }
                if !libraries.contains(library.path) { libraries.append(library.path) }
                environment["DYLD_INSERT_LIBRARIES"] = libraries.joined(separator: ":")
                environment["ONLINEFIX_CONFIG"] = files.config.path
                environment["ONLINEFIX_LOG"] = files.log.path
                environment["ONLINEFIX_SIG"] = files.runtime.path
                properties["LSEnvironment"] = environment
                let data = try PropertyListSerialization.data(fromPropertyList: properties, format: .xml, options: 0)
                try data.write(to: staging.appendingPathComponent("Contents/Info.plist"), options: .atomic)
                try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", staging.appendingPathComponent("Contents/MacOS/steam_osx").path])
                try Self.run("/usr/bin/codesign", ["--force", "--sign", "-", staging.path])
                try Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staging.path])
                guard try fingerprint(app) == originalHash else { throw ManagerError(message: "Steam changed during installation. Try again after quitting Steam.") }
                guard try verifyClient(steamRoot: steamRoot) == build else {
                    throw ManagerError(message: "Steam changed builds during installation. Quit Steam and retry.")
                }
                let record = Receipt(appPath: app.path, originalHash: originalHash, installedHash: try fingerprint(staging))
                try JSONEncoder().encode(record).write(to: receipt, options: .atomic)
                try swap(staging)
                exchanged = true
                try register()
            } catch {
                if exchanged {
                    do { try swap(staging); try? register() }
                    catch { throw ManagerError(message: "Rollback failed. Keep \(backup.path) and \(staging.path) for recovery.") }
                }
                try? fm.removeItem(at: staging)
                try? fm.removeItem(at: receipt)
                try? fm.removeItem(at: backup.deletingLastPathComponent())
                try? fm.removeItem(at: files.runtime)
                throw error
            }
            try? fm.removeItem(at: staging)
        }
    }

    func uninstall(steamRoot: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Steam")) throws {
        try locked {
            let fm = FileManager.default
            let record = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receipt))
            guard record.appPath == app.path else { throw ManagerError(message: "This backup belongs to a different Steam.app.") }
            let actual = try fingerprint(app)
            guard actual == record.installedHash else {
                throw ManagerError(message: "Steam changed after installation. Refusing to restore an older bundle. Keep the backup; use a clean Steam installation to recover.")
            }
            guard try fingerprint(backup) == record.originalHash else { throw ManagerError(message: "The backup changed or is incomplete. Steam was not modified.") }
            let configuration = try files.loadConfiguration()
            let fixes = configuration.fixes
            var updatedFixes = fixes
            var restoredLauncher: URL?
            var restoredPicoApp: URL?
            var restoredRepoDirectory: URL?
            var restoredPhasmDirectory: URL?
            var settingsChanged = false
            var exchanged = false
            let staging = app.deletingLastPathComponent().appendingPathComponent(".OnlineFix-restore-\(UUID().uuidString).app")
            try Self.run("/usr/bin/ditto", [backup.path, staging.path])
            do {
                if let index = fixes.firstIndex(where: { $0.id == 105600 && $0.patches.terrariaServerEnvironment }) {
                    guard let directory = try SteamLibrary.scan(root: steamRoot)
                        .first(where: { $0.id == 105600 })?.installDirectory else {
                        throw ManagerError(message: "Cannot locate Terraria to restore its server launcher. Reconnect its Steam library and retry uninstalling.")
                    }
                    let launcher = directory.appendingPathComponent("Terraria.app/Contents/MacOS/TerrariaServer")
                    try TerrariaServerPatch.setEnabled(false, launcher: launcher)
                    restoredLauncher = launcher
                    updatedFixes[index].patches.terrariaServerEnvironment = false
                }
                if let index = fixes.firstIndex(where: { $0.id == 2644470 && $0.picoPark2Photon }) {
                    guard let directory = try SteamLibrary.scan(root: steamRoot)
                        .first(where: { $0.id == 2644470 })?.installDirectory else {
                        throw ManagerError(message: "Cannot locate PICO PARK 2 to restore its Photon patch. Reconnect its Steam library and retry uninstalling.")
                    }
                    let picoApp = directory.appendingPathComponent("pico_park_2.app")
                    try PicoPark2Patch.setEnabled(false, app: picoApp)
                    restoredPicoApp = picoApp
                    updatedFixes[index].picoPark2Photon = false
                }
                if let index = fixes.firstIndex(where: { $0.id == 739630 && !$0.phasmophobiaPhotonAppID.isEmpty }) {
                    guard let directory = try SteamLibrary.scan(root: steamRoot)
                        .first(where: { $0.id == 739630 })?.installDirectory ?? fixes[index].installDirectory else {
                        throw ManagerError(message: "Cannot locate Phasmophobia to restore its files. Reconnect its Steam library and retry uninstalling.")
                    }
                    try PhasmophobiaPatch.setAppID("", directory: directory)
                    restoredPhasmDirectory = directory
                    updatedFixes[index].phasmophobiaPhotonAppID = ""
                }
                if let index = fixes.firstIndex(where: { $0.id == 3241660 && !$0.repoPhoton.isEmpty }) {
                    guard let directory = try SteamLibrary.scan(root: steamRoot)
                        .first(where: { $0.id == 3241660 })?.installDirectory ?? fixes[index].installDirectory else {
                        throw ManagerError(message: "Cannot locate R.E.P.O. to restore its files. Reconnect its Steam library and retry uninstalling.")
                    }
                    try RepoPatch.setAppIDs(RepoPhotonIDs(), directory: directory)
                    restoredRepoDirectory = directory
                    updatedFixes[index].repoPhoton = RepoPhotonIDs()
                }
                if updatedFixes != fixes {
                    try files.save(GameConfiguration(games: configuration.games, fixes: updatedFixes))
                    settingsChanged = true
                }
                try swap(staging)
                exchanged = true
                try register()
            } catch {
                let uninstallError = error
                do {
                    if exchanged { try swap(staging); try? register() }
                    if let directory = restoredRepoDirectory, let game = fixes.first(where: { $0.id == 3241660 }) {
                        try RepoPatch.setAppIDs(game.repoPhoton, directory: directory)
                    }
                    if let directory = restoredPhasmDirectory,
                       let game = fixes.first(where: { $0.id == 739630 }) {
                        try PhasmophobiaPatch.setAppID(game.phasmophobiaPhotonAppID, directory: directory)
                    }
                    if let picoApp = restoredPicoApp {
                        try PicoPark2Patch.setEnabled(true, app: picoApp)
                    }
                    if let launcher = restoredLauncher { try TerrariaServerPatch.setEnabled(true, launcher: launcher) }
                    if settingsChanged { try files.save(configuration) }
                } catch {
                    throw ManagerError(message: "Uninstall rollback failed. Keep the Steam backup, \(staging.path), and game-specific patch backups for recovery.\n\(error.localizedDescription)")
                }
                try? fm.removeItem(at: staging)
                throw uninstallError
            }
            try? fm.removeItem(at: staging)
            try fm.removeItem(at: receipt)
            try fm.removeItem(at: backup.deletingLastPathComponent())
            try fm.removeItem(at: files.runtime)
        }
    }
}
