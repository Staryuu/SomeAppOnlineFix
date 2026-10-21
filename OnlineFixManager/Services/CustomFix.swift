import CryptoKit
import Foundation

enum CustomFix {
    static let backupName = ".onlinefix-custom"
    static let lockName = ".onlinefix-custom.lock"
    static let defaultPassword = "online-fix.me"
    static let bridgeDLLs: Set<String> = ["steamclient", "steamclient64", "lsteamclient"]

    enum ArchiveError: LocalizedError {
        case password, invalid(String)
        var errorDescription: String? {
            switch self {
            case .password: "The archive password was rejected. Enter another password and retry."
            case .invalid(let message): message
            }
        }
    }

    struct Entry: Sendable, Equatable {
        let path: String
        let size: UInt64
    }

    struct Package: Sendable {
        let temporary: URL
        let content: URL
        let entries: [Entry]
        let declaredAppID: UInt32?
        var dlls: [String] {
            Array(Set(entries.compactMap { entry -> String? in
                let url = URL(fileURLWithPath: entry.path)
                guard url.pathExtension.lowercased() == "dll" else { return nil }
                let name = url.deletingPathExtension().lastPathComponent.lowercased()
                // Only emit shell-safe DLL names; preserve NotProton's Steam bridge overrides.
                guard !bridgeDLLs.contains(name), name.range(of: #"^[a-z0-9_.-]+$"#, options: .regularExpression) != nil else { return nil }
                return name
            })).sorted()
        }
        func discard() { try? FileManager.default.removeItem(at: temporary) }

        var recommendedDLLs: [String] {
            let fm = FileManager.default
            let runners = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/notproton/runners")
            var roots = (try? fm.contentsOfDirectory(at: runners, includingPropertiesForKeys: nil))?
                .map { $0.appendingPathComponent("CrossOver") } ?? []
            roots.append(URL(fileURLWithPath: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver"))
            var builtins = Set<String>()
            for root in roots {
                for architecture in ["x86_64-windows", "i386-windows"] {
                    let path = root.appendingPathComponent("lib/wine/\(architecture)")
                    for file in (try? fm.contentsOfDirectory(at: path, includingPropertiesForKeys: nil)) ?? [] where file.pathExtension.lowercased() == "dll" {
                        builtins.insert(file.deletingPathExtension().lastPathComponent.lowercased())
                    }
                }
            }
            return dlls.filter { builtins.contains($0) }
        }
    }

    struct FileRecord: Codable, Sendable {
        let path: String
        let originalHash: String?
        let installedHash: String
    }

    struct Receipt: Codable, Sendable {
        let directory: String
        let files: [FileRecord]
        let nativeDLLs: [String]
        let executable: String?
    }

    static func launchOptions(dlls: [String]) -> String {
        let safe = Set(dlls).filter {
            !bridgeDLLs.contains($0.lowercased()) && $0.range(of: #"^[a-z0-9_.-]+$"#, options: .regularExpression) != nil
        }.sorted()
        guard !safe.isEmpty else { return "%command%" }
        return "WINEDLLOVERRIDES=\"\(safe.map { "\($0)=n,b" }.joined(separator: ";"))\" %command%"
    }

    static func validatePath(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, path.utf8.count <= 1024,
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.contains("\\"), !path.contains(":"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && ![backupName, lockName].contains($0.lowercased()) }) else {
            throw ArchiveError.invalid("Unsafe archive path: \(path.debugDescription)")
        }
    }

    static func parseListing(_ listing: String) throws -> [Entry] {
        var entries: [Entry] = []
        var paths = Set<String>()
        var total: UInt64 = 0
        for block in listing.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n") where !block.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let separator = line.range(of: " = ") else { throw ArchiveError.invalid("Unsupported archive listing.") }
                let key = String(line[..<separator.lowerBound])
                guard fields[key] == nil else { throw ArchiveError.invalid("Ambiguous archive entry.") }
                fields[key] = String(line[separator.upperBound...])
            }
            guard let path = fields["Path"], let sizeText = fields["Size"], let size = UInt64(sizeText) else {
                throw ArchiveError.invalid("Incomplete archive entry.")
            }
            try validatePath(path)
            guard paths.insert(path.precomposedStringWithCanonicalMapping.lowercased()).inserted, paths.count <= 10000,
                  ["Symbolic Link", "Hard Link", "Copy Link"].allSatisfy({ (fields[$0] ?? "").isEmpty }),
                  fields["Alternate Stream"] != "+", !(fields["Attributes"] ?? "").contains("l") else {
                throw ArchiveError.invalid("Duplicate paths, links and alternate streams are not supported.")
            }
            guard size <= 1024 * 1024 * 1024, total <= 1024 * 1024 * 1024 - size else {
                throw ArchiveError.invalid("Custom fixes are limited to 1 GB unpacked and 10,000 entries.")
            }
            total += size
            let directory = fields["Folder"] == "+" || (fields["Attributes"] ?? "").hasPrefix("D")
            if !directory { entries.append(Entry(path: path, size: size)) }
        }
        guard !entries.isEmpty else { throw ArchiveError.invalid("The archive contains no files.") }
        return entries.sorted { $0.path < $1.path }
    }

    private static func run(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        environment["LC_ALL"] = "en_US.UTF-8"
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        var output = Data()
        while let data = try pipe.fileHandleForReading.read(upToCount: 65536), !data.isEmpty {
            output.append(data)
            if output.count > 8 * 1024 * 1024 {
                process.terminate()
                process.waitUntilExit()
                throw ArchiveError.invalid("Archive listing is too large.")
            }
        }
        process.waitUntilExit()
        let text = String(decoding: output, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if text.localizedCaseInsensitiveContains("wrong password") { throw ArchiveError.password }
            // Avoid including command arguments (including the password) in error messages.
            throw ArchiveError.invalid("Archive could not be read or extracted. Check that it is complete and uses a supported ZIP/RAR format.")
        }
        return text
    }

    static func prepare(archive: URL, password: String = defaultPassword, archiver: URL) throws -> Package {
        guard ["zip", "rar"].contains(archive.pathExtension.lowercased()) else { throw ArchiveError.invalid("Choose a ZIP or RAR file.") }
        let fm = FileManager.default
        guard let size = try fm.attributesOfItem(atPath: archive.path)[.size] as? NSNumber, size.uint64Value <= 1024 * 1024 * 1024 else {
            throw ArchiveError.invalid("Custom fix archives are limited to 1 GB.")
        }
        let temporary = fm.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("OnlineFix-import-\(UUID().uuidString)")
        try fm.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            let frozen = temporary.appendingPathComponent("archive.\(archive.pathExtension.lowercased())")
            try fm.copyItem(at: archive, to: frozen)
            let listing = try run(archiver, ["l", "-slt", "-ba", "-sccUTF-8", "-p\(password)", "--", frozen.path])
            // shortcut: paths must start at the game root; add source-folder selection for wrapped packages.
            let entries = try parseListing(listing)
            let content = temporary.appendingPathComponent("content")
            try fm.createDirectory(at: content, withIntermediateDirectories: false)
            _ = try run(archiver, ["x", "-y", "-bd", "-bb0", "-sccUTF-8", "-p\(password)", "-o\(content.path)", "--", frozen.path])
            // Reconcile extracted files with the preview before anything reaches the game folder.
            var actual = Set<String>()
            guard let enumerator = fm.enumerator(atPath: content.path) else { throw ArchiveError.invalid("Cannot inspect extracted files.") }
            while let path = enumerator.nextObject() as? String {
                let attributes = try fm.attributesOfItem(atPath: content.appendingPathComponent(path).path)
                let type = attributes[.type] as? FileAttributeType
                guard type == .typeRegular || type == .typeDirectory else { throw ArchiveError.invalid("Archive links and special files are not supported.") }
                if type == .typeRegular { actual.insert(path) }
            }
            let expected = Set(entries.map(\.path))
            guard actual == expected else {
                throw ArchiveError.invalid("Extracted files do not match the archive listing. Missing: \(expected.subtracting(actual).sorted()). Unexpected: \(actual.subtracting(expected).sorted()).")
            }
            for entry in entries {
                let attributes = try fm.attributesOfItem(atPath: content.appendingPathComponent(entry.path).path)
                guard (attributes[.size] as? NSNumber)?.uint64Value == entry.size else { throw ArchiveError.invalid("Extracted file size does not match the listing.") }
            }
            var declaredAppID: UInt32?
            for entry in entries where URL(fileURLWithPath: entry.path).lastPathComponent.lowercased() == "onlinefix.ini" {
                guard entry.size <= 65536 else { throw ArchiveError.invalid("OnlineFix.ini is too large to inspect.") }
                let data = try Data(contentsOf: content.appendingPathComponent(entry.path))
                guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252) else {
                    throw ArchiveError.invalid("OnlineFix.ini uses an unsupported text encoding.")
                }
                for line in text.components(separatedBy: .newlines) {
                    let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                    if parts.count == 2 && parts[0].lowercased() == "realappid" {
                        let value = parts[1].components(separatedBy: CharacterSet(charactersIn: ";#")).first!
                            .trimmingCharacters(in: .whitespaces)
                        guard let id = UInt32(value), ManagedGame.validID(id), declaredAppID == nil || declaredAppID == id else {
                            throw ArchiveError.invalid("The package has an invalid or conflicting RealAppId.")
                        }
                        declaredAppID = id
                    }
                }
            }
            return Package(temporary: temporary, content: content, entries: entries, declaredAppID: declaredAppID)
        } catch {
            try? fm.removeItem(at: temporary)
            throw error
        }
    }

    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 65536), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // Check every existing path component, so game-folder symlinks cannot redirect a write.
    static func checkedURL(_ path: String, in root: URL) throws -> URL {
        try validatePath(path)
        let fm = FileManager.default
        var current = root
        let parts = path.split(separator: "/")
        for (index, part) in parts.enumerated() {
            current.appendPathComponent(String(part))
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fm.attributesOfItem(atPath: current.path) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { continue }
            let expected: FileAttributeType = index == parts.count - 1 ? .typeRegular : .typeDirectory
            guard attributes[.type] as? FileAttributeType == expected else {
                throw ArchiveError.invalid("A destination is a link, directory or special file: \(path)")
            }
        }
        return current
    }

    static func receipt(in directory: URL) throws -> Receipt? {
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let backup = root.appendingPathComponent(backupName)
        guard FileManager.default.fileExists(atPath: backup.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: backup.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw ArchiveError.invalid("The custom-fix backup is not a regular directory.") }
        let url = try checkedURL("receipt.json", in: backup)
        let record = try JSONDecoder().decode(Receipt.self, from: Data(contentsOf: url))
        guard record.directory == root.path, !record.files.isEmpty, record.files.count <= 10000 else {
            throw ArchiveError.invalid("This backup belongs to a different game folder or is incomplete.")
        }
        var seen = Set<String>()
        for file in record.files {
            try validatePath(file.path)
            guard seen.insert(file.path.lowercased()).inserted else { throw ArchiveError.invalid("Duplicate backup entries.") }
        }
        return record
    }

    static func locked(directory: URL, operation: () throws -> Void) throws {
        let lock = directory.appendingPathComponent(lockName)
        do { try FileManager.default.createDirectory(at: lock, withIntermediateDirectories: false) }
        catch { throw ArchiveError.invalid("Cannot lock the game folder. Another custom-fix operation may be running, or the folder is not writable. After an interrupted operation, keep the backup and remove \(lockName) before retrying.") }
        defer { try? FileManager.default.removeItem(at: lock) }
        try operation()
    }

    static func install(_ package: Package, directory: URL, nativeDLLs: [String], executable: String? = nil) throws {
        if let executable { try validatePath(executable) }
        try locked(directory: directory) { try installUnlocked(package, directory: directory, nativeDLLs: nativeDLLs, executable: executable) }
    }

    private static func installUnlocked(_ package: Package, directory: URL, nativeDLLs: [String], executable: String?) throws {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let backup = root.appendingPathComponent(backupName)
        guard !fm.fileExists(atPath: backup.path) else { throw ArchiveError.invalid("A custom fix or recovery backup already exists. Restore it first.") }
        guard !(try SteamLibrary.windowsExecutables(in: root)).isEmpty else {
            throw ArchiveError.invalid("Choose the Windows game installation folder. No .exe file was found.")
        }
        var records: [FileRecord] = []
        for entry in package.entries {
            let target = try checkedURL(entry.path, in: root)
            records.append(FileRecord(path: entry.path, originalHash: fm.fileExists(atPath: target.path) ? try hash(target) : nil,
                                      installedHash: try hash(package.content.appendingPathComponent(entry.path))))
        }
        try fm.createDirectory(at: backup, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var committed = false
        do {
            let originals = backup.appendingPathComponent("originals")
            try fm.createDirectory(at: originals, withIntermediateDirectories: false)
            for record in records where record.originalHash != nil {
                let source = try checkedURL(record.path, in: root)
                let target = originals.appendingPathComponent(record.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: target)
                guard try hash(target) == record.originalHash else { throw ArchiveError.invalid("Game files changed during backup. Quit the game and retry.") }
            }
            let receipt = Receipt(directory: root.path, files: records, nativeDLLs: package.dlls.filter { nativeDLLs.contains($0) }, executable: executable)
            try JSONEncoder().encode(receipt).write(to: backup.appendingPathComponent("receipt.json"), options: .atomic)
            committed = true
            for record in records {
                let target = try checkedURL(record.path, in: root)
                let current = fm.fileExists(atPath: target.path) ? try hash(target) : nil
                guard current == record.originalHash else { throw ArchiveError.invalid("A game file changed during installation. Keep the backup.") }
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let data = try Data(contentsOf: package.content.appendingPathComponent(record.path))
                try data.write(to: target, options: .atomic)
            }
        } catch {
            if committed {
                do { try restoreUnlocked(directory: root) }
                catch { throw ArchiveError.invalid("Installation was interrupted and automatic restore could not finish. Keep \(backup.path) for recovery.\n\(error.localizedDescription)") }
            } else { try? fm.removeItem(at: backup) }
            throw error
        }
    }

    static func restore(directory: URL) throws {
        try locked(directory: directory) { try restoreUnlocked(directory: directory) }
    }

    static func remove(directory: URL) throws {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        let backup = root.appendingPathComponent(backupName)
        if !fm.fileExists(atPath: root.path) {
            try WineDLLSettings.restore(backup: backup)
            return
        }
        try locked(directory: root) {
            let record = try receipt(in: root)
            let executable = try record?.executable ?? WineDLLSettings.gameExecutable(directory: root)
            let gameExists: Bool
            if let executable {
                let url = try checkedURL(executable, in: root)
                gameExists = fm.fileExists(atPath: url.path)
            } else {
                gameExists = try SteamLibrary.windowsExecutables(in: root).contains { !$0.lowercased().contains("crashhandler") }
            }
            if gameExists, record != nil {
                try restoreUnlocked(directory: root, preserveChangedConfigurations: false)
            } else {
                try WineDLLSettings.restore(backup: backup)
                if fm.fileExists(atPath: backup.path) { try fm.removeItem(at: backup) }
            }
        }
    }

    private static func restoreUnlocked(directory: URL, preserveChangedConfigurations: Bool = true) throws {
        let fm = FileManager.default
        let root = directory.resolvingSymlinksInPath().standardizedFileURL
        guard let receipt = try receipt(in: root) else { throw ArchiveError.invalid("No custom-fix backup was found.") }
        let backup = root.appendingPathComponent(backupName)
        let originals = backup.appendingPathComponent("originals")
        guard try fm.attributesOfItem(atPath: originals.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw ArchiveError.invalid("The originals backup is not a regular directory.")
        }
        var changedConfigurations: [(path: String, hash: String)] = []
        // Validate the entire restore first; never overwrite files changed by a game update.
        for file in receipt.files {
            let target = try checkedURL(file.path, in: root)
            let current = fm.fileExists(atPath: target.path) ? try hash(target) : nil
            if let current, current != file.originalHash && current != file.installedHash {
                // OnlineFix can rewrite its INI at runtime; preserve the edited copy before removing the fix.
                guard URL(fileURLWithPath: file.path).lastPathComponent.lowercased() == "onlinefix.ini" else {
                    throw ArchiveError.invalid("Game file changed after installation: \(file.path). Restore blocked; keep the backup.")
                }
                changedConfigurations.append((file.path, current))
            }
            if let original = file.originalHash {
                let source = try checkedURL(file.path, in: originals)
                guard try hash(source) == original else { throw ArchiveError.invalid("A backup file changed. Restore blocked.") }
            }
        }
        let preserved = backup.appendingPathComponent("changed-configurations")
        if preserveChangedConfigurations && !changedConfigurations.isEmpty {
            let attempt = preserved.appendingPathComponent(UUID().uuidString)
            try fm.createDirectory(at: attempt, withIntermediateDirectories: true)
            for file in changedConfigurations {
                let source = try checkedURL(file.path, in: root)
                let copy = attempt.appendingPathComponent(file.path)
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: copy)
                guard try hash(copy) == file.hash else {
                    throw ArchiveError.invalid("The configuration changed during recovery. Quit the game before removing the fix.")
                }
            }
        }
        try WineDLLSettings.restore(backup: backup)
        for file in receipt.files {
            let target = try checkedURL(file.path, in: root)
            if file.originalHash != nil {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(contentsOf: originals.appendingPathComponent(file.path)).write(to: target, options: .atomic)
            } else if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        }
        if preserveChangedConfigurations && fm.fileExists(atPath: preserved.path) {
            let recovery = ManagerFiles.standard.directory.appendingPathComponent("removed-custom-fixes")
            try fm.createDirectory(at: recovery, withIntermediateDirectories: true)
            try fm.moveItem(at: backup, to: recovery.appendingPathComponent(UUID().uuidString))
        } else {
            try fm.removeItem(at: backup)
        }
    }
}
