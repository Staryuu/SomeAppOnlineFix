import AppKit
import SwiftUI

private enum ManagerPane: String {
    case games, add, fixes, installation, logs
    var title: String {
        switch self {
        case .games: "My Games"
        case .add: "Add Games"
        case .fixes: "Fix"
        case .installation: "Installation"
        case .logs: "Logs"
        }
    }

}

struct ManagerView: View {
    @AppStorage("steamAppPath") private var steamPath = "/Applications/Steam.app"
    @ViewState private var games: [ManagedGame] = []
    @ViewState private var fixes: [ManagedGame] = []
    @ViewState private var library: [ManagedGame] = []
    @ViewState private var query = ""
    @ViewState private var installed = false
    @ViewState private var busy = false
    @ViewState private var configLoaded = false
    @ViewState private var message = ""
    @ViewState private var error: String?
    @ViewState private var log = ""
    @ViewState private var selectedPane: ManagerPane? = .games
    @FocusState private var searchFocused: Bool
    @ViewState private var storeResults: [ManagedGame] = []
    @ViewState private var searching = false
    @ViewState private var searchError: String?
    @ViewState private var patchGame: ManagedGame?
    @ViewState private var fixGame: ManagedGame?
    @ViewState private var customGames: [ManagedGame] = []
    @ViewState private var selectedCustomGame: ManagedGame?

    private var fixGames: [ManagedGame] {
        GameConfiguration(games: games, fixes: fixes).fixGames(in: library)
    }

    private let files = ManagerFiles.standard
    private var installer: SteamInstaller {
        SteamInstaller(app: URL(fileURLWithPath: steamPath, isDirectory: true).resolvingSymlinksInPath(), files: files,
                       resources: Bundle.main.resourceURL!.appendingPathComponent("runtime", isDirectory: true))
    }
    private var matches: [ManagedGame] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return [] }
        var results = library.filter { $0.name.localizedCaseInsensitiveContains(term) || String($0.id) == term }
        for game in storeResults where !results.contains(where: { $0.id == game.id }) { results.append(game) }
        return results
    }
    private var inputID: UInt32? {
        guard let id = UInt32(query.trimmingCharacters(in: .whitespacesAndNewlines)), ManagedGame.validID(id) else { return nil }
        return id
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedPane) {
                Section("Library") {
                    Label("My Games", systemImage: "gamecontroller").tag(ManagerPane.games)
                    Label("Add Games", systemImage: "plus.app").tag(ManagerPane.add)
                    Label("Fix", systemImage: "wrench.and.screwdriver").tag(ManagerPane.fixes)
                }
                Section("Manage") {
                    Label("Installation", systemImage: "arrow.down.app").tag(ManagerPane.installation)
                    Label("Logs", systemImage: "text.alignleft").tag(ManagerPane.logs)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 240)
            .safeAreaInset(edge: .top) {
                HStack(spacing: 10) {
                    Image(systemName: "network").font(.title2).foregroundStyle(.tint)
                    Text("OnlineFix").font(.headline)
                    Spacer()
                }.padding(.horizontal, 16).padding(.vertical, 18)
            }
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(installed ? "Installed" : "Not installed", systemImage: installed ? "checkmark.circle.fill" : "circle")
                        .font(.callout).foregroundStyle(installed ? Color.green : Color.secondary)
                    Text("Session AppID 480").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
        } detail: {
            Group {
                switch selectedPane ?? .games {
                case .games: gamesPane
                case .add: addPane
                case .fixes: fixesPane
                case .installation: settingsPane
                case .logs: logsPane
                }
            }
            .navigationTitle((selectedPane ?? .games).title)
            .toolbar {
                ToolbarItemGroup {
                    Button { Task { await reload() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        .help("Refresh games and installation status")
                    Button { NSWorkspace.shared.open(URL(fileURLWithPath: steamPath)) } label: {
                        Label("Open Steam", systemImage: "play.fill")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if busy || !message.isEmpty {
                    VStack(spacing: 0) {
                        Divider()
                        HStack(spacing: 10) {
                            if busy { ProgressView().controlSize(.small) }
                            else { Image(systemName: "checkmark.circle").foregroundStyle(.green) }
                            Text(message).font(.callout).foregroundStyle(.secondary)
                            Spacer()
                        }.padding(.horizontal, 24).padding(.vertical, 12)
                    }
                }
            }
        }
        .frame(minWidth: 820, minHeight: 560)
        .disabled(busy)
        .sheet(item: $patchGame) { game in
            GamePatchView(game: game) { updated in
                guard let index = games.firstIndex(where: { $0.id == updated.id }) else { return false }
                var next = games
                next[index] = updated
                return save(next)
            }
        }
        .sheet(item: $fixGame) { game in
            GameFixView(game: game, supportsNativePatch: game.nativePatchApp != nil, onSave: saveFix)
                .alert("Cannot update fix", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                    Button("OK", role: .cancel) { error = nil }
                } message: { Text(error ?? "") }
        }
        .sheet(item: $selectedCustomGame) { game in
            CustomFixView(library: library, initialGame: game.id == 0 ? nil : game,
                          onRemember: rememberCustomFix, onRemove: removeCustomFix)
        }
        .onChange(of: selectedPane) { _, pane in searchFocused = pane == .add }
        .task { await reload() }
        .task(id: query) { await searchStore() }
        .task {
            while !Task.isCancelled {
                log = files.logTail()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
        .alert("OnlineFix Manager", isPresented: Binding(get: { error != nil && fixGame == nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var gamesPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            if !games.isEmpty {
                HStack {
                    Text("\(games.count) enabled \(games.count == 1 ? "game" : "games")").foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Game", systemImage: "plus") { selectedPane = .add }.buttonStyle(.borderedProminent)
                }
            }
            if !installed && !games.isEmpty {
                HStack {
                    Label("Install OnlineFix to use your game list.", systemImage: "info.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Set Up") { selectedPane = .installation }
                }.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }
            if games.isEmpty {
                ContentUnavailableView {
                    Label("No games yet", systemImage: "gamecontroller")
                } description: {
                    Text("Add a game to your OnlineFix list.")
                } actions: {
                    Button("Add Game") { selectedPane = .add }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(games) { game in gameRow(game, enabled: true) }
                    }
                }
                Text("Relaunch the game after changing its settings. Manager can be closed while you play.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var addPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Find your game").font(.title2.bold())
                Text("Search Steam or enter an AppID. The game doesn't need to be installed.")
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Game name or AppID", text: $query)
                    .textFieldStyle(.plain).focused($searchFocused)
                    .accessibilityLabel("Game name or AppID").onSubmit { addInput() }
                if searching { ProgressView().controlSize(.small) }
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }
            .padding(12)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
            if let searchError {
                Label(searchError, systemImage: "wifi.slash").font(.callout).foregroundStyle(.secondary)
            }
            if !matches.isEmpty || inputID != nil {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(matches) { game in gameRow(game, enabled: false) }
                        if let id = inputID, !matches.contains(where: { $0.id == id }) {
                            gameRow(ManagedGame(id: id, name: "AppID \(id)"), enabled: false)
                        }
                    }
                }
            } else if query.isEmpty {
                ContentUnavailableView("Search Steam", systemImage: "magnifyingglass",
                                       description: Text("Find a game by name, or add it using its Steam AppID."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searching {
                Spacer()
                HStack { Spacer(); Text("Searching Steam…").foregroundStyle(.secondary); Spacer() }
                Spacer()
            } else {
                ContentUnavailableView(query.count < 3 ? "Keep typing" : "No games found", systemImage: "magnifyingglass",
                    description: Text(query.count < 3 ? "Enter at least 3 characters to search." : "Try another name or enter a Steam AppID."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var fixesPane: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("Available fixes").font(.title2.bold())
                Spacer()
                Button("Custom Fix…", systemImage: "shippingbox") { selectedCustomGame = ManagedGame(id: 0, name: "Custom Fix") }
                    .buttonStyle(.borderedProminent)
            }
            Text("Fix game files here. Steam settings are in My Games → Patch.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if !customGames.isEmpty {
                    Text("Custom Fixes").font(.headline)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)], alignment: .leading, spacing: 16) {
                    ForEach(customGames) { game in
                        Button { selectedCustomGame = game } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                GameArtwork(game: game).frame(height: 112).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(game.name).font(.headline).lineLimit(1)
                                    Text("Custom Fix · AppID \(String(game.id))").font(.caption).foregroundStyle(.secondary)
                                    Text("by online-fix.me").font(.caption).foregroundStyle(.secondary)
                                    Text("Windows / NotProton").font(.caption).foregroundStyle(.secondary)
                                }.padding([.horizontal, .bottom], 14)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
                        }.buttonStyle(.plain)
                    }
                }
                    }
                    Text("Built-in Fixes").font(.headline)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 16)], alignment: .leading, spacing: 16) {
                        ForEach(fixGames) { game in fixCard(game) }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Install a game, then refresh your library.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fixCard(_ game: ManagedGame) -> some View {
        Button { fixGame = game } label: {
            VStack(alignment: .leading, spacing: 0) {
                GameArtwork(game: game)
                .frame(height: 112).clipped().accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text(game.name).font(.headline).lineLimit(1)
                    Text(game.id == 105600 ? "Server environment fix" : "Photon multiplayer fix")
                        .font(.callout).foregroundStyle(.secondary)
                    Text([739630, 3241660].contains(game.id) ? "Windows / NotProton" : "Native macOS")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Label(game.fileFixInstalled ? "Installed" : "Not installed",
                              systemImage: game.fileFixInstalled ? "checkmark.circle.fill" : "arrow.down.circle")
                            .foregroundStyle(game.fileFixInstalled ? Color.green : Color.secondary)
                        Spacer(minLength: 0)
                        if game.hasFileFix { Text("Fix active").foregroundStyle(.green) }
                    }.font(.caption)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .disabled(!configLoaded)
        .accessibilityLabel("\(game.name), \(game.fileFixInstalled ? "installed" : "not installed"), view fix")
    }

    private func gameRow(_ game: ManagedGame, enabled: Bool) -> some View {
        HStack(spacing: 16) {
            GameArtwork(game: game)
            .frame(width: 140, height: 66).clipShape(RoundedRectangle(cornerRadius: 7)).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(game.name).font(.headline).lineLimit(2)
                Text("AppID \(String(game.id))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if enabled {
                Button("Patch") { patchGame = game }
                Menu {
                    Button("Remove Game", role: .destructive) { save(games.filter { $0.id != game.id }) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(game.name)")
            } else {
                let added = games.contains(where: { $0.id == game.id })
                Button(added ? "Added" : "Add Game") { add(game) }
                    .disabled(!configLoaded || added)
            }
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
    }

    private func searchStore() async {
        storeResults = []
        searchError = nil
        searching = false
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard term.count >= 3, UInt32(term) == nil else { return }
        do {
            try await Task.sleep(for: .milliseconds(350))
            searching = true
            let results = try await SteamStore.search(term)
            try Task.checkCancellation()
            storeResults = results
            searching = false
        } catch {
            if !Task.isCancelled {
                searching = false
                searchError = "Steam search failed. Installed games and manual AppID entry are still available."
            }
        }
    }

    private var settingsPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Install once. Play as usual.").font(.title2.bold())
                    Text("OnlineFix loads with Steam. Manager doesn't need to stay open.").foregroundStyle(.secondary)
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 14) {
                            Image(systemName: installed ? "checkmark.circle.fill" : "arrow.down.app")
                                .font(.system(size: 30)).foregroundStyle(installed ? Color.green : Color.accentColor)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(installed ? "OnlineFix is installed" : "Ready to install").font(.headline)
                                Text(installed ? "Launch games from Steam normally." : "Quit Steam before continuing.").foregroundStyle(.secondary)
                            }
                            Spacer()
                            if installed {
                                Button("Uninstall", role: .destructive) { modifyInstallation(remove: true) }
                            } else {
                                Button("Install OnlineFix") { modifyInstallation(remove: false) }
                                    .buttonStyle(.borderedProminent).disabled(!configLoaded)
                            }
                        }
                        Divider()
                        Text("Steam is re-signed locally. A verified backup is saved before installation and restored on removal.")
                            .font(.callout).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox("Steam location") {
                    HStack(spacing: 16) {
                        Image(systemName: "app.dashed").font(.title2).foregroundStyle(.secondary)
                        Text(steamPath).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button("Choose…") { chooseSteam() }
                    }.padding(12)
                }
                GroupBox("Settings & logs") {
                    HStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Your game list and logs are kept after uninstalling.")
                            Text(files.directory.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Show Folder") {
                            do {
                                try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
                                NSWorkspace.shared.open(files.directory)
                            } catch { self.error = error.localizedDescription }
                        }
                    }.padding(12)
                }
                Text("Steam updates may require reinstalling OnlineFix. Run one game at a time.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }

    private func chooseSteam() {
        let panel = NSOpenPanel()
        panel.title = "Choose Steam.app"
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            steamPath = url.resolvingSymlinksInPath().path
            installed = installer.isInstalled()
        }
    }

    private var logsPane: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Activity log").font(.title2.bold())
                    Text("Steam keeps logging after you close Manager.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([files.log]) }
            }
            ScrollView([.horizontal, .vertical]) {
                Text(log).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.5)))
            Text("Last 64 KB · refreshes every 2 seconds").font(.caption).foregroundStyle(.secondary)
        }.padding(24)
    }

    private func reload() async {
        var errors: [String] = []
        do { customGames = try files.loadCustomFixes() }
        catch { errors.append("Cannot load custom fixes.\n\(error.localizedDescription)") }
        do {
            let configuration = try files.loadConfiguration()
            games = configuration.games
            fixes = configuration.fixes
            configLoaded = true
        } catch { configLoaded = false; errors.append("Cannot load games.json. The existing file was not changed.\n\(error.localizedDescription)") }
        installed = installer.isInstalled()
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        do { library = try await Task.detached { try SteamLibrary.scan(root: root) }.value }
        catch { errors.append("Cannot scan the Steam library: \(error.localizedDescription)") }
        if configLoaded, let game = fixGames.first(where: { $0.id == 2644470 }), let app = game.nativePatchApp {
            do {
                let enabled = try await Task.detached { try PicoPark2Patch.isEnabled(app: app) }.value
                var status = fixes.first(where: { $0.id == game.id }) ?? game
                status.installDirectory = game.installDirectory
                status.picoPark2Photon = enabled
                try rememberFix(status)
            } catch { errors.append("Cannot verify the PICO PARK 2 fix.\n\(error.localizedDescription)") }
        }
        if configLoaded, let game = fixGames.first(where: { $0.id == 3241660 }), game.fileFixInstalled, let directory = game.installDirectory {
            do {
                let ids = try await Task.detached { try RepoPatch.appIDs(directory: directory) }.value
                var status = fixes.first(where: { $0.id == game.id }) ?? game
                status.installDirectory = directory
                status.repoPhoton = ids
                try rememberFix(status)
            } catch { errors.append("Cannot verify the R.E.P.O. fix.\n\(error.localizedDescription)") }
        }
        if configLoaded, let game = fixGames.first(where: { $0.id == 739630 }), game.fileFixInstalled, let directory = game.installDirectory {
            do {
                let appID = try await Task.detached { try PhasmophobiaPatch.appID(directory: directory) }.value
                var status = fixes.first(where: { $0.id == game.id }) ?? game
                status.installDirectory = directory
                status.phasmophobiaPhotonAppID = appID
                try rememberFix(status)
            } catch { errors.append("Cannot verify the Phasmophobia fix.\n\(error.localizedDescription)") }
        }
        if !errors.isEmpty { self.error = errors.joined(separator: "\n\n") }
    }

    private func removeCustomFix(_ id: UInt32) throws {
        let next = try files.loadCustomFixes().filter { $0.id != id }
        try files.saveCustomFixes(next)
        customGames = next
    }

    private func rememberCustomFix(_ game: ManagedGame) throws {
        var next = try files.loadCustomFixes()
        if let index = next.firstIndex(where: { $0.id == game.id }) { next[index] = game }
        else { next.append(game) }
        try files.saveCustomFixes(next)
        customGames = next
    }

    private func rememberFix(_ game: ManagedGame) throws {
        var next = fixes
        if let index = next.firstIndex(where: { $0.id == game.id }) {
            guard next[index] != game else { return }
            next[index] = game
        } else {
            guard game.hasFileFix else { return }
            next.append(game)
        }
        try files.save(GameConfiguration(games: games, fixes: next))
        fixes = next
    }

    @discardableResult private func save(_ next: [ManagedGame]) -> Bool {
        guard configLoaded else { return false }
        do {
            try files.save(GameConfiguration(games: next, fixes: fixes))
            games = next
            message = "Saved. Relaunch the affected game to apply changes."
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult private func saveFix(_ updated: ManagedGame) -> Bool {
        var next = fixes
        if let index = next.firstIndex(where: { $0.id == updated.id }) { next[index] = updated.fileFixSettings }
        else { next.append(updated.fileFixSettings) }
        guard configLoaded else { return false }
        let previous = fixes.contains { $0.id == 105600 && $0.patches.terrariaServerEnvironment }
        let enabled = next.contains { $0.id == 105600 && $0.patches.terrariaServerEnvironment }
        let previousPico = fixes.contains { $0.id == 2644470 && $0.picoPark2Photon }
        let enabledPico = next.contains { $0.id == 2644470 && $0.picoPark2Photon }
        let previousPhasm: String = fixes.first(where: { $0.id == 739630 })?.phasmophobiaPhotonAppID ?? ""
        let nextPhasm: String = next.first(where: { $0.id == 739630 })?.phasmophobiaPhotonAppID ?? ""
        var changedLauncher: URL?
        var changedPicoApp: URL?
        let previousRepo: RepoPhotonIDs = fixes.first(where: { $0.id == 3241660 })?.repoPhoton ?? RepoPhotonIDs()
        let nextRepo: RepoPhotonIDs = next.first(where: { $0.id == 3241660 })?.repoPhoton ?? RepoPhotonIDs()
        var changedRepoDirectory: URL?
        var changedPhasmDirectory: URL?
        do {
            try GameConfiguration(games: games, fixes: next).validate()
            if previous != enabled {
                if enabled, library.first(where: { $0.id == 105600 })?.nativePatchApp == nil {
                    throw ManagerError(message: "The Terraria server fix requires the native macOS installation. Windows versions through NotProton are not supported.")
                }
                if let directory = library.first(where: { $0.id == 105600 })?.installDirectory
                    ?? fixes.first(where: { $0.id == 105600 })?.installDirectory {
                    let launcher = directory.appendingPathComponent("Terraria.app/Contents/MacOS/TerrariaServer")
                    try TerrariaServerPatch.setEnabled(enabled, launcher: launcher)
                    changedLauncher = launcher
                } else if enabled {
                    throw ManagerError(message: "Install Terraria and refresh the Steam library before enabling its server fix.")
                }
            }
            if previousPico != enabledPico {
                if enabledPico, library.first(where: { $0.id == 2644470 })?.nativePatchApp == nil {
                    throw ManagerError(message: "The PICO PARK 2 Photon fix requires the native macOS installation. Windows versions through NotProton are not supported.")
                }
                guard let directory = library.first(where: { $0.id == 2644470 })?.installDirectory
                    ?? fixes.first(where: { $0.id == 2644470 })?.installDirectory else {
                    throw ManagerError(message: "Install PICO PARK 2 and refresh the Steam library before changing its Photon patch.")
                }
                let app = directory.appendingPathComponent("pico_park_2.app")
                try PicoPark2Patch.setEnabled(enabledPico, app: app)
                changedPicoApp = app
            }
            if previousPhasm != nextPhasm {
                guard let directory = library.first(where: { $0.id == 739630 })?.installDirectory
                    ?? fixes.first(where: { $0.id == 739630 })?.installDirectory else {
                    throw ManagerError(message: "Install Phasmophobia and refresh the Steam library before changing its Photon patch.")
                }
                try PhasmophobiaPatch.setAppID(nextPhasm, directory: directory)
                changedPhasmDirectory = directory
            }
            if previousRepo != nextRepo {
                guard let directory = library.first(where: { $0.id == 3241660 })?.installDirectory
                    ?? fixes.first(where: { $0.id == 3241660 })?.installDirectory else {
                    throw ManagerError(message: "Install R.E.P.O. and refresh the Steam library before changing its Photon patch.")
                }
                try RepoPatch.setAppIDs(nextRepo, directory: directory)
                changedRepoDirectory = directory
            }
            try files.save(GameConfiguration(games: games, fixes: next))
            fixes = next
            message = "Saved. Relaunch the affected game to apply changes."
            return true
        }
        catch {
            let saveError = error
            do {
                if let directory = changedRepoDirectory {
                    try RepoPatch.setAppIDs(previousRepo, directory: directory)
                }
                if let directory = changedPhasmDirectory {
                    try PhasmophobiaPatch.setAppID(previousPhasm, directory: directory)
                }
                if let app = changedPicoApp {
                    try PicoPark2Patch.setEnabled(previousPico, app: app)
                }
                if let launcher = changedLauncher {
                    try TerrariaServerPatch.setEnabled(previous, launcher: launcher)
                }
            } catch {
                self.error = "Settings could not be saved and a game patch could not be restored. Keep the game-specific patch backups.\n\(error.localizedDescription)"
                return false
            }
            self.error = saveError.localizedDescription
            return false
        }
    }

    private func add(_ game: ManagedGame) {
        guard !games.contains(where: { $0.id == game.id }) else { return }
        save((games + [game]).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        query = ""
    }

    private func addInput() {
        if let id = inputID { add(library.first(where: { $0.id == id }) ?? ManagedGame(id: id, name: "AppID \(id)")) }
        else if matches.count == 1 { add(matches[0]) }
        else { error = "Choose a search result or enter a valid Steam AppID. AppID 480 is the routing target and cannot be added." }
    }

    private func modifyInstallation(remove: Bool) {
        if let steam = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated &&
            ($0.bundleIdentifier == "com.valvesoftware.steam" || $0.executableURL?.lastPathComponent == "steam_osx") &&
            SteamInstaller.processExists($0.processIdentifier)
        }) {
            error = "Steam is still running (PID \(steam.processIdentifier)). Quit Steam before installing or removing OnlineFix."
            return
        }
        let target = installer
        busy = true
        InstallationActivity.busy = true
        message = remove ? "Restoring the Steam backup…" : "Backing up Steam and installing OnlineFix…"
        Task {
            defer { busy = false; InstallationActivity.busy = false }
            do {
                try await Task.detached {
                    if remove { try target.uninstall() } else { try target.install() }
                }.value
                installed = target.isInstalled()
                if remove {
                    let configuration = try files.loadConfiguration()
                    games = configuration.games
                    fixes = configuration.fixes
                }
                message = remove ? "OnlineFix removed. Your game list and logs were kept." : "Installed. Launch Steam normally; you can close Manager now."
            } catch { self.error = error.localizedDescription; message = ""; installed = target.isInstalled() }
        }
    }
}
