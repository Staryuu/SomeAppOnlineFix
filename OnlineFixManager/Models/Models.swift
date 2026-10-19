import Foundation

struct ManagerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct RepoPhotonIDs: Codable, Equatable, Sendable {
    var realtime = ""
    var voice = ""
    var isEmpty: Bool { realtime.isEmpty && voice.isEmpty }
    var isValid: Bool {
        realtime.withCString { pun in voice.withCString { of_repo_validate_ids(pun, $0) } }
    }
}

struct ManagedGame: Codable, Identifiable, Equatable {
    let id: UInt32
    var name: String
    var keepRealAppID = false
    var imageURL: URL? = nil
    var patches = PatchSettings()
    var installDirectory: URL? = nil
    // Keep Manager-only file patches outside Steam's strict runtime patch settings.
    var picoPark2Photon = false
    var phasmophobiaPhotonAppID = ""
    var repoPhoton = RepoPhotonIDs()

    static let fileFixCatalog = [
        ManagedGame(id: 105600, name: "Terraria"),
        ManagedGame(id: 2644470, name: "PICO PARK 2"),
        ManagedGame(id: 739630, name: "Phasmophobia"),
        ManagedGame(id: 3241660, name: "R.E.P.O.")
    ]

    var supportsFileFix: Bool { Self.fileFixCatalog.contains { $0.id == id } }
    var hasFileFix: Bool { patches.terrariaServerEnvironment || picoPark2Photon || !phasmophobiaPhotonAppID.isEmpty || !repoPhoton.isEmpty }
    var fileFixInstalled: Bool {
        if id == 3241660 {
            guard let installDirectory else { return false }
            return FileManager.default.fileExists(atPath: installDirectory.appendingPathComponent("REPO_Data/Managed/Assembly-CSharp.dll").path)
        }
        if id != 739630 { return nativePatchApp != nil }
        guard let installDirectory else { return false }
        return ["GameAssembly.dll", "Phasmophobia_Data/resources.assets", "Phasmophobia_Data/il2cpp_data/Metadata/global-metadata.dat"]
            .allSatisfy { FileManager.default.fileExists(atPath: installDirectory.appendingPathComponent($0).path) }
    }

    var steamSettings: ManagedGame {
        var game = self
        game.patches.terrariaServerEnvironment = false
        game.picoPark2Photon = false
        game.phasmophobiaPhotonAppID = ""
        game.repoPhoton = RepoPhotonIDs()
        return game
    }

    var fileFixSettings: ManagedGame {
        var game = self
        game.keepRealAppID = false
        game.patches = PatchSettings()
        game.patches.terrariaServerEnvironment = patches.terrariaServerEnvironment
        return game
    }

    var nativePatchApp: URL? {
        guard let installDirectory else { return nil }
        let bundle: String
        let target: String
        switch id {
        case 105600:
            bundle = "Terraria.app"
            target = "Contents/MacOS/TerrariaServer"
        case 2644470:
            bundle = "pico_park_2.app"
            target = "Contents/Frameworks/GameAssembly.dylib"
        default: return nil
        }
        let app = installDirectory.appendingPathComponent(bundle, isDirectory: true)
        return FileManager.default.fileExists(atPath: app.appendingPathComponent(target).path) ? app : nil
    }

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
    private enum CodingKeys: String, CodingKey { case id, name, keepRealAppID, imageURL, patches, installDirectory, picoPark2Photon, phasmophobiaPhotonAppID, repoPhoton }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UInt32.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        keepRealAppID = try values.decode(Bool.self, forKey: .keepRealAppID)
        imageURL = try values.decodeIfPresent(URL.self, forKey: .imageURL)
        patches = values.contains(.patches) ? try values.decode(PatchSettings.self, forKey: .patches) : PatchSettings()
        installDirectory = try values.decodeIfPresent(URL.self, forKey: .installDirectory)
        picoPark2Photon = values.contains(.picoPark2Photon) ? try values.decode(Bool.self, forKey: .picoPark2Photon) : false
        repoPhoton = values.contains(.repoPhoton) ? try values.decode(RepoPhotonIDs.self, forKey: .repoPhoton) : RepoPhotonIDs()
        phasmophobiaPhotonAppID = values.contains(.phasmophobiaPhotonAppID) ? try values.decode(String.self, forKey: .phasmophobiaPhotonAppID) : ""
    }
}

struct GameConfiguration: Codable, Equatable {
    var games: [ManagedGame]
    var fixes: [ManagedGame]

    init(games: [ManagedGame], fixes: [ManagedGame] = []) {
        self.games = games
        self.fixes = fixes
    }

    var separatedFileFixes: GameConfiguration {
        var value = GameConfiguration(games: games.map(\.steamSettings), fixes: fixes.map(\.fileFixSettings))
        // Move existing file fixes without changing which games use Steam routing.
        for game in games where game.hasFileFix && !value.fixes.contains(where: { $0.id == game.id }) {
            value.fixes.append(game.fileFixSettings)
        }
        return value
    }

    func fixGames(in library: [ManagedGame]) -> [ManagedGame] {
        return ManagedGame.fileFixCatalog.map { entry in
            let game = library.first(where: { $0.id == entry.id }) ?? entry
            var fix = fixes.first(where: { $0.id == game.id }) ?? game.fileFixSettings
            fix.name = game.name
            fix.imageURL = game.imageURL ?? fix.imageURL
            fix.installDirectory = game.installDirectory ?? fix.installDirectory
            return fix
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private enum CodingKeys: String, CodingKey { case games, fixes }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let games = try values.decode([ManagedGame].self, forKey: .games)
        let fixes = values.contains(.fixes) ? try values.decode([ManagedGame].self, forKey: .fixes) : []
        self.init(games: games, fixes: fixes)
    }

    func validate() throws {
        for list in [games, fixes] {
            guard list.allSatisfy({ ManagedGame.validID($0.id) && !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
                  Set(list.map(\.id)).count == list.count,
                  list.allSatisfy({ !$0.patches.terrariaServerEnvironment || $0.id == 105600 }),
                  list.allSatisfy({ !$0.picoPark2Photon || $0.id == 2644470 }),
                  list.allSatisfy({ $0.repoPhoton.isEmpty || ($0.id == 3241660 && $0.repoPhoton.isValid) }),
                  list.allSatisfy({ $0.phasmophobiaPhotonAppID.isEmpty || ($0.id == 739630 && PhasmophobiaPatch.validateAppID($0.phasmophobiaPhotonAppID)) }) else {
                throw ManagerError(message: "The game or fix list contains invalid settings or duplicate AppIDs.")
            }
        }
        guard fixes.allSatisfy(\.supportsFileFix) else { throw ManagerError(message: "The fix list contains an unsupported game.") }
    }
}
