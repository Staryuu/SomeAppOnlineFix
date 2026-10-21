import Foundation

struct ManagerFiles: Sendable {
    let directory: URL
    static let standard = ManagerFiles(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OnlineFixManager", isDirectory: true))
    var config: URL { directory.appendingPathComponent("games.json") }
    var log: URL { directory.appendingPathComponent("onlinefix.log") }
    var runtime: URL { directory.appendingPathComponent("runtime", isDirectory: true) }
    private var customFixes: URL { directory.appendingPathComponent("custom-fixes.json") }

    func loadCustomFixes() throws -> [ManagedGame] {
        guard FileManager.default.fileExists(atPath: customFixes.path) else { return [] }
        let data = try Data(contentsOf: customFixes)
        guard data.count <= 1024 * 1024 else { throw ManagerError(message: "The custom fix list is too large.") }
        let games = try JSONDecoder().decode([ManagedGame].self, from: data)
        try validateCustomFixes(games)
        return games
    }

    func saveCustomFixes(_ games: [ManagedGame]) throws {
        try validateCustomFixes(games)
        let data = try JSONEncoder().encode(games)
        guard data.count <= 1024 * 1024 else { throw ManagerError(message: "The custom fix list is too large.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: customFixes, options: .atomic)
    }

    private func validateCustomFixes(_ games: [ManagedGame]) throws {
        guard Set(games.map(\.id)).count == games.count,
              games.allSatisfy({ ManagedGame.validID($0.id) && !$0.name.isEmpty && $0.installDirectory?.isFileURL == true }) else {
            throw ManagerError(message: "Custom fixes need unique, valid AppIDs and local game folders.")
        }
    }

    func load() throws -> [ManagedGame] {
        try loadConfiguration().games
    }

    func loadConfiguration() throws -> GameConfiguration {
        if !FileManager.default.fileExists(atPath: config.path) { return GameConfiguration(games: []) }
        let data = try Data(contentsOf: config)
        guard data.count <= 1024 * 1024 else { throw ManagerError(message: "The configuration is too large.") }
        let value = try JSONDecoder().decode(GameConfiguration.self, from: data)
        try value.validate()
        return value.separatedFileFixes
    }

    func save(_ games: [ManagedGame]) throws {
        try save(GameConfiguration(games: games, fixes: loadConfiguration().fixes))
    }

    func save(_ value: GameConfiguration) throws {
        try value.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value.separatedFileFixes)
        guard data.count <= 1024 * 1024 else { throw ManagerError(message: "The configuration is too large.") }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: config, options: .atomic)
    }

    func logTail() -> String {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return "No log yet. Launch Steam after installing OnlineFix." }
        defer { try? handle.close() }
        do {
            let size = try handle.seekToEnd()
            try handle.seek(toOffset: size > 65536 ? size - 65536 : 0)
            return String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
        } catch { return "Unable to read the log: \(error.localizedDescription)" }
    }
}
