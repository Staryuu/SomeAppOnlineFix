import Foundation

enum SteamStore {
    private struct SearchResponse: Decodable {
        struct Item: Decodable {
            let id: UInt32
            let name: String
            let type: String
            let tiny_image: URL?
        }
        let items: [Item]
    }

    static func request(for term: String) -> URLRequest {
        var url = URLComponents(string: "https://store.steampowered.com/api/storesearch/")!
        url.queryItems = [URLQueryItem(name: "term", value: term), URLQueryItem(name: "l", value: "english"),
                          URLQueryItem(name: "cc", value: "US")]
        var request = URLRequest(url: url.url!, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func decode(_ data: Data) throws -> [ManagedGame] {
        guard data.count <= 2 * 1024 * 1024 else { throw ManagerError(message: "Steam returned an oversized search response.") }
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        var seen = Set<UInt32>()
        return response.items.prefix(100).compactMap { item in
            guard item.type == "app", ManagedGame.validID(item.id), !item.name.isEmpty,
                  item.name.count <= 512, seen.insert(item.id).inserted else { return nil }
            return ManagedGame(id: item.id, name: item.name, imageURL: item.tiny_image)
        }
    }

    static func search(_ term: String) async throws -> [ManagedGame] {
        // shortcut: public Store search endpoint is undocumented; keep manual AppID entry if Valve changes it.
        let (data, response) = try await URLSession.shared.data(for: request(for: term))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ManagerError(message: "Steam search is temporarily unavailable. Try again or enter an AppID.")
        }
        return try decode(data)
    }
}
