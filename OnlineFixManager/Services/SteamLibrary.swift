import Foundation

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
