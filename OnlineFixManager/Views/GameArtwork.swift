import SwiftUI

struct GameArtwork: View {
    let game: ManagedGame
    @ViewState private var attempt = 0
    @ViewState private var resolvedURL: URL?
    @ViewState private var lookupAttempted = false

    private var urls: [URL] {
        var urls = [game.artworkURL,
                    URL(string: "https://cdn.akamai.steamstatic.com/steam/apps/\(game.id)/header.jpg")!,
                    URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(game.id)/library_600x900_2x.jpg")!]
        if let imageURL = game.imageURL, imageURL.scheme == "https", !urls.contains(imageURL) { urls.append(imageURL) }
        if let resolvedURL, !urls.contains(resolvedURL) { urls.append(resolvedURL) }
        return urls
    }

    var body: some View {
        GeometryReader { size in
            ZStack {
                Color.secondary.opacity(0.1)
                if attempt < urls.count {
                    AsyncImage(url: urls[attempt]) { phase in
                        switch phase {
                        case .success(let image): image.resizable().scaledToFill()
                        case .failure: placeholder.onAppear { attempt += 1 }
                        default: placeholder
                        }
                    }.id(urls[attempt])
                } else {
                    placeholder.task(id: game.id) {
                        guard !lookupAttempted else { return }
                        lookupAttempted = true
                        if let url = try? await SteamStore.artwork(for: game.id), !Task.isCancelled { resolvedURL = url }
                    }
                }
            }.frame(width: size.size.width, height: size.size.height).clipped()
        }
        .onChange(of: game.id) { _, _ in attempt = 0; resolvedURL = nil; lookupAttempted = false }
        .onChange(of: game.imageURL) { _, _ in attempt = 0 }
    }

    private var placeholder: some View {
        VStack(spacing: 4) {
            Image(systemName: "gamecontroller").font(.title2)
            Text(game.name).font(.caption).lineLimit(2).multilineTextAlignment(.center)
        }.foregroundStyle(.secondary).padding(8)
    }
}
