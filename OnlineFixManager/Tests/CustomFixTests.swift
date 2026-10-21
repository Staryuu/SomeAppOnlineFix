import Foundation

enum CustomFixChecks {
    static func run(archiver: URL, temporary: URL) throws {
        let fm = FileManager.default
        let source = temporary.appendingPathComponent("custom-source")
        let game = temporary.appendingPathComponent("custom-game")
        try fm.createDirectory(at: source.appendingPathComponent("Data/Plugins"), withIntermediateDirectories: true)
        try fm.createDirectory(at: game.appendingPathComponent("Data/Plugins"), withIntermediateDirectories: true)
        let original = Data("original steam api".utf8)
        let replacement = Data("replacement steam api".utf8)
        let apiPath = "Data/Plugins/steam_api64.dll"
        try original.write(to: game.appendingPathComponent(apiPath))
        try Data("MZ fixture".utf8).write(to: game.appendingPathComponent("Game.exe"))
        let settings = ManagerFiles(directory: temporary.appendingPathComponent("custom-settings"))
        try ManagerChecks.check(settings.loadCustomFixes().isEmpty)
        var customGame = ManagedGame(id: 2644470, name: "PICO PARK 2")
        customGame.installDirectory = game
        try settings.saveCustomFixes([customGame])
        try ManagerChecks.check(settings.loadCustomFixes() == [customGame])
        precondition(customGame.artworkURL.absoluteString.contains("/2644470/header.jpg"))
        try ManagerChecks.expectFailure { try settings.saveCustomFixes([customGame, customGame]) }
        var invalidGame = ManagedGame(id: 0, name: "Invalid")
        invalidGame.installDirectory = game
        try ManagerChecks.expectFailure { try settings.saveCustomFixes([invalidGame]) }
        var missingFolder = customGame
        missingFolder.installDirectory = nil
        try ManagerChecks.expectFailure { try settings.saveCustomFixes([missingFolder]) }
        try ManagerChecks.check(settings.loadCustomFixes() == [customGame])
        try replacement.write(to: source.appendingPathComponent(apiPath))
        for name in ["winmm.dll", "Custom.dll", "steamclient64.dll"] {
            try Data("fixture DLL, never executed".utf8).write(to: source.appendingPathComponent(name))
        }
        let zip = temporary.appendingPathComponent("custom-encrypted.zip")
        let process = Process()
        process.executableURL = archiver
        process.arguments = ["a", "-tzip", "-palternate-password", zip.path, "."]
        process.currentDirectoryURL = source
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        do {
            let unexpected = try CustomFix.prepare(archive: zip, archiver: archiver)
            unexpected.discard()
            preconditionFailure("Default password should be rejected")
        } catch CustomFix.ArchiveError.password { }
        let package = try CustomFix.prepare(archive: zip, password: "alternate-password", archiver: archiver)
        defer { package.discard() }
        precondition(package.entries.count == 4)
        precondition(package.dlls == ["custom", "steam_api64", "winmm"])
        precondition(CustomFix.launchOptions(dlls: package.dlls) == "WINEDLLOVERRIDES=\"custom=n,b;steam_api64=n,b;winmm=n,b\" %command%")
        precondition(CustomFix.launchOptions(dlls: ["bad\";touch pwn", "steamclient64", "lsteamclient"]) == "%command%")
        for path in ["../escape", "/absolute", "C:/absolute", "Data\\escape", "a//b", "a/./b", "a/../b", "a\nPath = fake", ".onlinefix-custom/receipt.json"] {
            try ManagerChecks.expectFailure { try CustomFix.validatePath(path) }
        }
        for listing in [
            "Path = ../escape\nSize = 1\n",
            "Path = winmm.dll\nSize = 1\nSymbolic Link = /tmp/escape\n",
            "Path = winmm.dll\nSize = 1\n\nPath = WINMM.dll\nSize = 1\n",
            "Path = winmm.dll\nSize = 1073741825\n",
            "Path = winmm.dll\nPath = fake\nSize = 1\n"
        ] { try ManagerChecks.expectFailure { _ = try CustomFix.parseListing(listing) } }
        let linked = game.appendingPathComponent("linked")
        try fm.createSymbolicLink(at: linked, withDestinationURL: source)
        try ManagerChecks.expectFailure { _ = try CustomFix.checkedURL("linked/winmm.dll", in: game) }
        try fm.removeItem(at: linked)
        let lock = game.appendingPathComponent(CustomFix.lockName)
        try fm.createDirectory(at: lock, withIntermediateDirectories: false)
        try ManagerChecks.expectFailure(containing: "Cannot lock") { try CustomFix.install(package, directory: game, nativeDLLs: []) }
        try fm.removeItem(at: lock)
        // A collision is rejected before any game file is touched.
        try fm.createDirectory(at: game.appendingPathComponent("winmm.dll"), withIntermediateDirectories: false)
        try ManagerChecks.expectFailure { try CustomFix.install(package, directory: game, nativeDLLs: package.dlls) }
        try ManagerChecks.check(Data(contentsOf: game.appendingPathComponent(apiPath)) == original)
        try fm.removeItem(at: game.appendingPathComponent("winmm.dll"))
        try CustomFix.install(package, directory: game, nativeDLLs: package.dlls)
        try ManagerChecks.check(Data(contentsOf: game.appendingPathComponent(apiPath)) == replacement)
        try ManagerChecks.check(CustomFix.receipt(in: game)?.nativeDLLs == package.dlls)
        try ManagerChecks.expectFailure { try CustomFix.install(package, directory: game, nativeDLLs: []) }
        // An updated game or damaged backup must block the entire restore.
        let updated = Data("game update".utf8)
        try updated.write(to: game.appendingPathComponent(apiPath))
        try ManagerChecks.expectFailure(containing: "changed after") { try CustomFix.restore(directory: game) }
        precondition(fm.fileExists(atPath: game.appendingPathComponent("winmm.dll").path))
        try ManagerChecks.check(Data(contentsOf: game.appendingPathComponent(apiPath)) == updated)
        try replacement.write(to: game.appendingPathComponent(apiPath))
        let backupAPI = game.appendingPathComponent("\(CustomFix.backupName)/originals/\(apiPath)")
        try updated.write(to: backupAPI)
        try ManagerChecks.expectFailure(containing: "backup file changed") { try CustomFix.restore(directory: game) }
        try original.write(to: backupAPI)
        // Restore can resume after an interruption where some originals are already back.
        try original.write(to: game.appendingPathComponent(apiPath))
        try CustomFix.restore(directory: game)
        try ManagerChecks.check(Data(contentsOf: game.appendingPathComponent(apiPath)) == original)
        precondition(!fm.fileExists(atPath: game.appendingPathComponent("winmm.dll").path))
        precondition(!fm.fileExists(atPath: game.appendingPathComponent(CustomFix.backupName).path))
        // Optional local package check: only installs into this disposable fixture, never the real game.
        if let archive = ProcessInfo.processInfo.environment["ONLINEFIX_TEST_RAR"] {
            let rar = try CustomFix.prepare(archive: URL(fileURLWithPath: archive), archiver: archiver)
            defer { rar.discard() }
            try CustomFix.install(rar, directory: game, nativeDLLs: rar.dlls)
            try ManagerChecks.check(CustomFix.receipt(in: game)?.files.count == rar.entries.count)
            try CustomFix.restore(directory: game)
            print("Local RAR passed: \(rar.entries.count) files, native DLLs: \(rar.dlls.joined(separator: ", "))")
        }
        print("Custom Fix checks passed: encrypted ZIP password retry, path/link guards, bridge exclusions, native options, install, backup validation and resumable restore.")
    }
}
