import CryptoKit
import Foundation

enum WineDLLSettings {
    private struct Value: Codable {
        let name: String
        let original: String?
        let installed: String
    }
    private struct Record: Codable {
        let prefix: URL
        let executable: String
        let values: [Value]
        let overlay: Overlay?
    }
    private struct Overlay: Codable, Equatable {
        let path: String
        let hash: String
    }
    private static let filename = "dll-settings.json"
    private static let wineRoot = "HKEY_CURRENT_USER\\Software\\Wine"

    private static func backupURL(directory: URL) -> URL {
        let hash = SHA256.hash(data: Data(directory.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return ManagerFiles.standard.directory.appendingPathComponent("dll-backups/\(hash).json")
    }

    private static func existingBackup(directory: URL) throws -> URL? {
        let central = backupURL(directory: directory)
        if FileManager.default.fileExists(atPath: central.path) { return central }
        let legacy = try CustomFix.checkedURL(filename, in: directory.appendingPathComponent(CustomFix.backupName))
        return FileManager.default.fileExists(atPath: legacy.path) ? legacy : nil
    }

    static func hasBackup(directory: URL) -> Bool {
        (try? existingBackup(directory: directory)) != nil
    }

    static func keepBackupOutsideGame(directory: URL) throws {
        let central = backupURL(directory: directory)
        guard !FileManager.default.fileExists(atPath: central.path), let source = try existingBackup(directory: directory) else { return }
        let data = try Data(contentsOf: source)
        _ = try JSONDecoder().decode(Record.self, from: data)
        try FileManager.default.createDirectory(at: central.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: central, options: .atomic)
    }

    static func gameExecutable(directory: URL) throws -> String? {
        guard let url = try existingBackup(directory: directory) else { return nil }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        _ = try key(record.executable)
        return record.executable
    }

    static func prefix(appID: UInt32, directory: URL) throws -> URL {
        guard ManagedGame.validID(appID) else { throw ManagerError(message: "Select a valid game first.") }
        var folder = directory
        while folder.path != "/" && folder.lastPathComponent != "steamapps" { folder.deleteLastPathComponent() }
        guard folder.lastPathComponent == "steamapps" else {
            throw ManagerError(message: "Cannot locate this game's NotProton prefix. Select its Steam installation folder.")
        }
        let prefix = folder.appendingPathComponent("compatdata/\(appID)/pfx")
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("user.reg").path) else {
            throw ManagerError(message: "Launch this game once with NotProton to create its prefix, then quit it and apply DLL settings.")
        }
        return prefix
    }

    private static func key(_ executable: String) throws -> String {
        guard executable.lowercased().hasSuffix(".exe"), !executable.isEmpty,
              !executable.contains("\\"), !executable.contains("/"),
              !executable.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw ManagerError(message: "Choose a valid game executable.")
        }
        return "HKEY_CURRENT_USER\\Software\\Wine\\AppDefaults\\\(executable)\\DllOverrides"
    }

    private static func run(prefix: URL, arguments: [String]) throws -> String {
        let fm = FileManager.default
        let compat = prefix.deletingLastPathComponent()
        let build = try String(contentsOf: compat.appendingPathComponent("notproton-build"), encoding: .utf8)
            .components(separatedBy: .newlines).first ?? ""
        guard build.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil else {
            throw ManagerError(message: "Cannot identify this prefix's NotProton runner.")
        }
        let runner = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/notproton/runners/crossover-\(build)/CrossOver")
        let log = try String(contentsOf: compat.appendingPathComponent("notproton-run.log"), encoding: .utf8)
        let architecture: String
        if log.contains(runner.path + "/lib/wine/aarch64-unix/") { architecture = "aarch64-unix" }
        else if log.contains(runner.path + "/lib/wine/x86_64-unix/") { architecture = "x86_64-unix" }
        else { throw ManagerError(message: "Launch the game once with NotProton so its Wine runner can be identified.") }
        let unix = runner.appendingPathComponent("lib/wine/\(architecture)")
        let wine = unix.appendingPathComponent(architecture == "aarch64-unix" ? "wine.app/Contents/MacOS/wine" : "wine")
        var server = runner.appendingPathComponent(architecture == "aarch64-unix" ? "bin/wineserver-arm64" : "bin/wineserver")
        if !fm.isExecutableFile(atPath: server.path) { server = runner.appendingPathComponent("bin/wineserver-x86") }
        guard fm.isExecutableFile(atPath: wine.path), fm.isExecutableFile(atPath: server.path) else {
            throw ManagerError(message: "The NotProton Wine runner is missing. Repair it in NotProton first.")
        }
        let process = Process()
        process.executableURL = wine
        process.arguments = ["reg.exe"] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        environment.removeValue(forKey: "WINEDLLOVERRIDES")
        environment["WINEPREFIX"] = prefix.path
        environment["WINELOADER"] = wine.path
        environment["WINESERVER"] = server.path
        environment["CX_ROOT"] = runner.path
        environment["CX_HOME"] = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/CrossOver").path
        environment["WINEDLLPATH"] = runner.appendingPathComponent("lib/wine/x86_64-windows").path + ":" + unix.path
        environment["WINEDEBUG"] = "-all"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ManagerError(message: "Wine could not read or update DLL settings. Quit the game and retry. The recovery backup was kept.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ManagerError(message: "Wine returned an unsupported text encoding. Use Wine Configuration for these DLL settings.")
        }
        return text
    }

    private static func values(prefix: URL, root: String, target: String, names: [String]) throws -> [String: String] {
        let text = try run(prefix: prefix, arguments: ["query", root, "/s"])
        let root = root.lowercased()
        // Wine omits an empty parent heading; a successful query can contain only subkeys or no entries.
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.components(separatedBy: .newlines).contains(where: {
            let path = $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return path == root || path.hasPrefix(root + "\\")
        }) else { throw ManagerError(message: "Wine returned an unreadable registry listing. No DLL settings were changed.") }
        var inTarget = false
        var result: [String: String] = [:]
        let expression = try NSRegularExpression(pattern: #"^\s+(\S+)\s+(REG_[A-Z0-9_]+)\s+(.*)$"#)
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("HKEY_") { inTarget = trimmed.caseInsensitiveCompare(target) == .orderedSame; continue }
            guard inTarget else { continue }
            let ns = line as NSString
            guard let match = expression.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let name = ns.substring(with: match.range(at: 1)).lowercased()
            guard names.contains(name) else { continue }
            guard ns.substring(with: match.range(at: 2)) == "REG_SZ" else {
                throw ManagerError(message: "An existing DLL setting has an unsupported registry type: \(name)")
            }
            result[name] = ns.substring(with: match.range(at: 3)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private static func overlayPlan(directory: URL, prefix: URL) throws -> (Overlay, URL)? {
        guard let receipt = try CustomFix.receipt(in: directory),
              let entry = receipt.files.first(where: { URL(fileURLWithPath: $0.path).lastPathComponent.lowercased() == "steamoverlay64.dll" }) else { return nil }
        let overlay = try CustomFix.checkedURL(entry.path, in: directory)
        // This loader's saved analysis resolves GameOverlayRenderer64.dll beside ActiveProcess's SteamClientDll.
        guard try CustomFix.hash(overlay) == "f784b4b85b627c7ea541bd2a90c9fc6e9736a0731707c31265aa86fe684dc2df" else { return nil }
        let active = "HKEY_CURRENT_USER\\Software\\Valve\\Steam\\ActiveProcess"
        let settings = try values(prefix: prefix, root: active, target: active, names: ["steamclientdll"])
        guard let client = settings["steamclientdll"], client.lowercased().hasPrefix("c:\\") else {
            throw ManagerError(message: "Cannot locate the Steam client used by this overlay loader. No renderer was copied.")
        }
        let relativeClient = "drive_c/" + client.dropFirst(3).replacingOccurrences(of: "\\", with: "/")
        _ = try CustomFix.checkedURL(relativeClient, in: prefix)
        // shortcut: .DLL survives NotProton's lowercase *.dll cleanup; revisit if its cleanup becomes case-insensitive.
        let relative = (relativeClient as NSString).deletingLastPathComponent + "/GameOverlayRenderer64.DLL"
        let target = try CustomFix.checkedURL(relative, in: prefix)
        if FileManager.default.fileExists(atPath: target.path) { return nil }
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/notproton/bridge/legacycompat/GameOverlayRenderer64.dll")
        guard FileManager.default.isReadableFile(atPath: source.path) else {
            throw ManagerError(message: "NotProton's GameOverlayRenderer64.dll is missing. Repair the NotProton installation first.")
        }
        return (Overlay(path: relative, hash: try CustomFix.hash(source)), source)
    }

    private static func validateOverlay(_ overlay: Overlay?, prefix: URL) throws {
        guard let overlay else { return }
        let target = try CustomFix.checkedURL(overlay.path, in: prefix)
        if FileManager.default.fileExists(atPath: target.path), try CustomFix.hash(target) != overlay.hash {
            throw ManagerError(message: "The overlay renderer changed after installation. Keep the custom-fix backup; it will not be overwritten or removed.")
        }
    }

    private static func copyOverlay(_ plan: (Overlay, URL), prefix: URL) throws {
        let fm = FileManager.default
        let target = try CustomFix.checkedURL(plan.0.path, in: prefix)
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".OnlineFix-overlay-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temporary) }
        try fm.copyItem(at: plan.1, to: temporary)
        guard try CustomFix.hash(temporary) == plan.0.hash else { throw ManagerError(message: "Overlay renderer copy verification failed.") }
        try fm.moveItem(at: temporary, to: target)
    }

    static func apply(directory: URL, prefix: URL, executable: String, dlls: [String]) throws {
        guard !dlls.isEmpty else { return }
        _ = try key(executable)
        guard dlls.allSatisfy({ !CustomFix.bridgeDLLs.contains($0) && $0.range(of: #"^[a-z0-9_.-]+$"#, options: .regularExpression) != nil }) else {
            throw ManagerError(message: "Invalid DLL override name.")
        }
        try CustomFix.locked(directory: directory) {
            guard try CustomFix.receipt(in: directory) != nil else { throw ManagerError(message: "Install the fix files before applying DLL settings.") }
            let backup = directory.appendingPathComponent(CustomFix.backupName)
            let existing = try existingBackup(directory: directory)
            let previous = try existing.map { try JSONDecoder().decode(Record.self, from: Data(contentsOf: $0)) }
            let recordURL = backupURL(directory: directory)
            if let previous {
                guard previous.prefix.standardizedFileURL == prefix.standardizedFileURL,
                      previous.executable.caseInsensitiveCompare(executable) == .orderedSame,
                      Set(previous.values.map(\.name)) == Set(dlls) else {
                    throw ManagerError(message: "DLL settings belong to a different prefix, EXE or selection. Restore the custom fix first.")
                }
            }
            let originals = try values(prefix: prefix, root: wineRoot, target: key(executable), names: dlls)
            if let previous {
                for value in previous.values where originals[value.name] != value.original && originals[value.name] != value.installed {
                    throw ManagerError(message: "DLL settings changed after installation. Keep the backup and restore before changing settings.")
                }
            }
            try validateOverlay(previous?.overlay, prefix: prefix)
            let plan = try overlayPlan(directory: directory, prefix: prefix)
            if let existing = previous?.overlay, let plan, existing != plan.0 {
                throw ManagerError(message: "The overlay source or Steam path changed. Restore the existing custom fix first.")
            }
            let record = Record(prefix: prefix, executable: executable,
                                values: previous?.values ?? dlls.map { Value(name: $0, original: originals[$0], installed: "native,builtin") },
                                overlay: previous?.overlay ?? plan?.0)
            try FileManager.default.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(record).write(to: recordURL, options: .atomic)
            if let existing, existing != recordURL { try FileManager.default.removeItem(at: existing) }
            do {
                if let plan { try copyOverlay(plan, prefix: prefix) }
                for value in record.values {
                    _ = try run(prefix: prefix, arguments: ["add", try key(executable), "/v", value.name, "/t", "REG_SZ", "/d", value.installed, "/f"])
                }
            } catch {
                if previous != nil { throw error }
                let failure = error
                do { try restore(backup: backup) }
                catch { throw ManagerError(message: "DLL settings could not be fully restored. Keep the custom-fix backup.\n\(error.localizedDescription)") }
                throw failure
            }
        }
    }

    static func restore(backup: URL) throws {
        guard let url = try existingBackup(directory: backup.deletingLastPathComponent()) else { return }
        let record = try JSONDecoder().decode(Record.self, from: Data(contentsOf: url))
        try validateOverlay(record.overlay, prefix: record.prefix)
        if FileManager.default.fileExists(atPath: record.prefix.appendingPathComponent("user.reg").path) {
        let current = try values(prefix: record.prefix, root: wineRoot, target: key(record.executable), names: record.values.map(\.name))
        for value in record.values {
            guard current[value.name] == value.original || current[value.name] == value.installed else {
                throw ManagerError(message: "DLL settings changed after installation. Restore blocked; keep the backup.")
            }
        }
        for value in record.values {
            if let original = value.original {
                _ = try run(prefix: record.prefix, arguments: ["add", try key(record.executable), "/v", value.name, "/t", "REG_SZ", "/d", original, "/f"])
            } else if current[value.name] != nil {
                _ = try run(prefix: record.prefix, arguments: ["delete", try key(record.executable), "/v", value.name, "/f"])
            }
        }
        }
        if let overlay = record.overlay {
            let target = try CustomFix.checkedURL(overlay.path, in: record.prefix)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        }
        try FileManager.default.removeItem(at: url)
    }
}
