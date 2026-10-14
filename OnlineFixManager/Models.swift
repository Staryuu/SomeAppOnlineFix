import Foundation

struct ManagerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct ManagedGame: Codable, Identifiable, Equatable {
    let id: UInt32
    var name: String
    var keepRealAppID = false
    var imageURL: URL? = nil
    var patches = PatchSettings()
    var installDirectory: URL? = nil

    var artworkURL: URL {
        if let imageURL, imageURL.scheme == "https" { return imageURL }
        return URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(id)/header.jpg")!
    }

    static func validID(_ id: UInt32) -> Bool { id > 0 && id <= 0xffffff && id != 480 }
}

struct PatchSettings: Codable, Equatable {
    var startupAppID = true
    var overlayAppID = true
    var inputAppID = true
    var statsAppID = true
    var terrariaServerEnvironment = false
}

extension PatchSettings {
    init(from decoder: Decoder) throws {
        let values = try decoder.singleValueContainer().decode([String: Bool].self)
        let supported: Set<String> = ["startupAppID", "overlayAppID", "inputAppID", "statsAppID", "terrariaServerEnvironment"]
        guard Set(values.keys).isSubset(of: supported) else {
            throw ManagerError(message: "The configuration contains an unsupported patch. Update Manager before editing it.")
        }
        startupAppID = values["startupAppID"] ?? true
        overlayAppID = values["overlayAppID"] ?? true
        inputAppID = values["inputAppID"] ?? true
        statsAppID = values["statsAppID"] ?? true
        terrariaServerEnvironment = values["terrariaServerEnvironment"] ?? false
    }
}

extension ManagedGame {
    private enum CodingKeys: String, CodingKey { case id, name, keepRealAppID, imageURL, patches, installDirectory }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UInt32.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        keepRealAppID = try values.decode(Bool.self, forKey: .keepRealAppID)
        imageURL = try values.decodeIfPresent(URL.self, forKey: .imageURL)
        patches = values.contains(.patches) ? try values.decode(PatchSettings.self, forKey: .patches) : PatchSettings()
        installDirectory = try values.decodeIfPresent(URL.self, forKey: .installDirectory)
    }
}

struct GameConfiguration: Codable {
    var games: [ManagedGame]

    func validate() throws {
        guard games.allSatisfy({ ManagedGame.validID($0.id) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(games.map(\.id)).count == games.count,
              games.allSatisfy({ !$0.patches.terrariaServerEnvironment || $0.id == 105600 }) else {
            throw ManagerError(message: "The game list contains an invalid or duplicate AppID.")
        }
    }
}

struct ManagerFiles: Sendable {
    let directory: URL
    static let standard = ManagerFiles(directory: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/OnlineFixManager", isDirectory: true))
    var config: URL { directory.appendingPathComponent("games.json") }
    var log: URL { directory.appendingPathComponent("onlinefix.log") }
    var runtime: URL { directory.appendingPathComponent("runtime", isDirectory: true) }

    func load() throws -> [ManagedGame] {
        if !FileManager.default.fileExists(atPath: config.path) { return [] }
        let data = try Data(contentsOf: config)
        guard data.count <= 1024 * 1024 else { throw ManagerError(message: "The configuration is too large.") }
        let value = try JSONDecoder().decode(GameConfiguration.self, from: data)
        try value.validate()
        return value.games
    }

    func save(_ games: [ManagedGame]) throws {
        let value = GameConfiguration(games: games)
        try value.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
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

enum SteamLibrary {
    // VDF stores the fields we need as quoted key/value pairs; nested blocks stay untouched.
    static func pairs(_ text: String) -> [(String, String)] {
        let expression = try! NSRegularExpression(pattern: #""((?:\\.|[^"\\])*)"\s*"((?:\\.|[^"\\])*)""#)
        let ns = text as NSString
        func decode(_ range: NSRange) -> String {
            ns.substring(with: range).replacingOccurrences(of: #"\""#, with: "\"")
                .replacingOccurrences(of: #"\\"#, with: #"\"#)
        }
        return expression.matches(in: text, range: NSRange(location: 0, length: ns.length))
            .map { (decode($0.range(at: 1)), decode($0.range(at: 2))) }
    }

    static func scan(root: URL) throws -> [ManagedGame] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else { return [] }
        let folders = root.appendingPathComponent("steamapps/libraryfolders.vdf")
        var libraries = [root]
        if fm.fileExists(atPath: folders.path) {
            libraries += pairs(try String(contentsOf: folders, encoding: .utf8))
                .filter { $0.0 == "path" }.map { URL(fileURLWithPath: $0.1, isDirectory: true) }
        }
        var found: [UInt32: ManagedGame] = [:]
        for library in Set(libraries) {
            let apps = library.appendingPathComponent("steamapps", isDirectory: true)
            // An external library can be disconnected; the remaining libraries still work.
            guard let manifests = try? fm.contentsOfDirectory(at: apps, includingPropertiesForKeys: nil) else { continue }
            for manifest in manifests where manifest.lastPathComponent.hasPrefix("appmanifest_") && manifest.pathExtension == "acf" {
                guard let text = try? String(contentsOf: manifest, encoding: .utf8) else { continue }
                let values = pairs(text)
                guard let idText = values.first(where: { $0.0 == "appid" })?.1,
                      let id = UInt32(idText), ManagedGame.validID(id),
                      let name = values.first(where: { $0.0 == "name" })?.1, !name.isEmpty else { continue }
                var game = ManagedGame(id: id, name: name)
                if let directory = values.first(where: { $0.0 == "installdir" })?.1,
                   !directory.isEmpty, !directory.contains("/"), !directory.contains("\\"),
                   directory != ".", directory != ".." {
                    game.installDirectory = apps.appendingPathComponent("common", isDirectory: true)
                        .appendingPathComponent(directory, isDirectory: true)
                }
                found[id] = game
            }
        }
        return found.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
