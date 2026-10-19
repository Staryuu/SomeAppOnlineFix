import Foundation

struct ManagerFiles: Sendable {
    let directory: URL
    static let standard = ManagerFiles(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OnlineFixManager", isDirectory: true))
    var config: URL { directory.appendingPathComponent("games.json") }
    var log: URL { directory.appendingPathComponent("onlinefix.log") }
    var runtime: URL { directory.appendingPathComponent("runtime", isDirectory: true) }

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
