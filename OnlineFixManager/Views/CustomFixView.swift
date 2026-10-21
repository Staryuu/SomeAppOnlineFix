import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct CustomFixView: View {
    @Environment(\.dismiss) private var dismiss
    let library: [ManagedGame]
    let initialGame: ManagedGame?
    let onRemember: (ManagedGame) throws -> Void
    let onRemove: (UInt32) throws -> Void
    @ViewState private var step = 0
    @ViewState private var hasContinued = false
    @ViewState private var selectedID: UInt32 = 0
    @ViewState private var directory: URL?
    @ViewState private var archive: URL?
    @ViewState private var package: CustomFix.Package?
    @ViewState private var receipt: CustomFix.Receipt?
    @ViewState private var nativeDLLs: Set<String> = []
    @ViewState private var needsPassword = false
    @ViewState private var password = ""
    @ViewState private var busy = false
    @ViewState private var error: String?
    @ViewState private var message = ""
    @ViewState private var chosenGame: ManagedGame?
    @ViewState private var gameQuery = ""
    @ViewState private var storeResults: [ManagedGame] = []
    @ViewState private var searching = false
    @ViewState private var searchError: String?
    @ViewState private var selectedExecutable = ""
    @ViewState private var useGameRoot = false
    @ViewState private var dllSettingsApplied = false
    @ViewState private var executables: [String] = []
    @ViewState private var locating = false
    @ViewState private var locationMessage = "Choose an installed game or enter its Steam AppID first."

    private var validAppID: UInt32? {
        guard let id = chosenGame?.id, ManagedGame.validID(id) else { return nil }
        return id
    }

    private var matches: [ManagedGame] {
        let term = gameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, chosenGame == nil else { return [] }
        var matches = library.filter { $0.name.localizedCaseInsensitiveContains(term) || String($0.id) == term }
        for game in storeResults where !matches.contains(where: { $0.id == game.id }) { matches.append(game) }
        if let id = UInt32(term), ManagedGame.validID(id), !matches.contains(where: { $0.id == id }) {
            matches.append(ManagedGame(id: id, name: "AppID \(id)"))
        }
        return Array(matches.prefix(15))
    }

    private var destination: URL? {
        guard let directory else { return nil }
        if receipt != nil || useGameRoot || selectedExecutable.isEmpty { return directory }
        return directory.appendingPathComponent(selectedExecutable).deletingLastPathComponent()
    }

    private var packageMatchesGame: Bool {
        package?.declaredAppID == nil || package?.declaredAppID == validAppID
    }

    private var options: String {
        CustomFix.launchOptions(dlls: receipt?.nativeDLLs ?? Array(nativeDLLs))
    }

    private var canContinue: Bool {
        guard validAppID != nil, destination != nil, !executables.isEmpty, !locating else { return false }
        return step == 0 || (package != nil && packageMatchesGame)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Custom Fix · Prototype").font(.title2.bold())
            if initialGame == nil && !hasContinued {
                Spacer()
                VStack(alignment: .leading, spacing: 18) {
                    Label("Before installing a fix", systemImage: "exclamationmark.triangle.fill")
                        .font(.title3.bold())
                    Text("Choose the Generic fix from Online-Fix.me.")
                    Link("Open online-fix.me ↗", destination: URL(string: "https://online-fix.me/")!)
                    Text("Use the Windows version of the game and make sure its folder contains the game’s .exe file.")
                    Text("Run the game at least once with NotProton, then close it before installing the fix. This creates the NotProton prefix needed for DLL settings.")
                    Text("Fixes that require a dedicated launcher and macOS games are not supported yet.")
                        .foregroundStyle(.secondary)
                    HStack {
                        Button("Cancel", role: .cancel) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                        Spacer()
                        Button("Continue") { hasContinued = true }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                Spacer()
            } else {
            Text("Windows / NotProton · Quit the game before installing or restoring.")
                .font(.callout).foregroundStyle(.secondary)
            if receipt == nil {
                Text(["Step 1 of 3 · Choose game", "Step 2 of 3 · Choose fix", "Step 3 of 3 · Install"][step])
                    .font(.headline)
                ProgressView(value: Double(step + 1), total: 3)
            }
            Form {
                if step == 0 && receipt == nil {
                Section("1 · Choose game") {
                    TextField("Game name or Steam AppID (required)", text: $gameQuery)
                        .disabled(receipt != nil)
                    if searching { ProgressView("Searching Steam…").controlSize(.small) }
                    if let searchError { Text(searchError).font(.caption).foregroundStyle(.secondary) }
                    ForEach(matches) { game in
                        Button { chooseGame(game) } label: {
                            HStack {
                                GameArtwork(game: game).frame(width: 90, height: 42).clipShape(RoundedRectangle(cornerRadius: 4))
                                VStack(alignment: .leading) {
                                    Text(game.name)
                                    Text("AppID \(String(game.id))").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                            }
                        }.buttonStyle(.plain)
                    }
                    HStack(alignment: .top, spacing: 14) {
                        if let game = chosenGame {
                            GameArtwork(game: game)
                            .frame(width: 154, height: 72).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                            .accessibilityLabel("Steam cover for \(game.name)")
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            if let game = chosenGame {
                                Text(game.name).font(.headline)
                                Text("AppID \(String(game.id))").font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Choose a game from the results or installed library before continuing.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Picker("Installed game", selection: $selectedID) {
                        Text("Choose a game or enter an AppID").tag(UInt32(0))
                        ForEach(library.filter { $0.installDirectory != nil }) { game in
                            Text(game.name).tag(game.id)
                        }
                    }
                    .disabled(receipt != nil)
                    HStack {
                        Text(directory?.path ?? "Game folder not selected")
                            .font(.caption).textSelection(.enabled)
                        Spacer()
                        Button("Choose Folder…") { chooseDirectory() }.disabled(validAppID == nil)
                    }
                    if locating { ProgressView("Finding game files…").controlSize(.small) }
                    Text(locationMessage).font(.caption).foregroundStyle(.secondary)
                    if !executables.isEmpty {
                        DisclosureGroup("Advanced · executable and folder") {
                        Picker("Game executable", selection: $selectedExecutable) {
                            ForEach(executables, id: \.self) { executable in
                                Text(executable).tag(executable)
                            }
                        }.disabled(receipt != nil)
                        if let directory, destination != directory, receipt == nil {
                            Toggle("Install at the game folder root instead", isOn: $useGameRoot)
                        } else if useGameRoot && receipt == nil {
                            Toggle("Install at the game folder root instead", isOn: $useGameRoot)
                        }
                        if let destination {
                            Text("Fix destination: \(destination.path)").font(.caption).textSelection(.enabled)
                        }
                        }
                    }
                }
                }
                if let receipt {
                    Section("Installed custom fix / recovery backup") {
                        if let game = chosenGame {
                            HStack(spacing: 14) {
                                GameArtwork(game: game).frame(width: 154, height: 72).clipShape(RoundedRectangle(cornerRadius: 6))
                                VStack(alignment: .leading) {
                                    Text(game.name).font(.headline)
                                    Text("AppID \(String(game.id))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        Text("\(receipt.files.count) files recorded. Restore checks file hashes before replacing anything.")
                        Text(executables.isEmpty
                             ? "Game files are missing. Remove will restore DLL settings and delete the remaining backup and Custom Fix entry."
                             : "Remove restores original files and DLL settings, then deletes the backup and Custom Fix entry.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if step == 1 && validAppID != nil && !executables.isEmpty && !locating {
                    Section("2 · Choose fix ZIP / RAR") {
                        HStack {
                            Text(archive?.lastPathComponent ?? "No archive selected")
                            Spacer()
                            Button("Choose Archive…") { chooseArchive() }
                        }
                        Text("Tries online-fix.me automatically. Passwords are not saved.")
                            .font(.caption).foregroundStyle(.secondary)
                        if needsPassword {
                            SecureField("Archive password (leave empty for no password)", text: $password)
                            Button("Retry Password") { prepare(password: password) }
                        }
                    }
                    if let package {
                        if !packageMatchesGame {
                            Text("This package declares AppID \(String(package.declaredAppID!)), which does not match the selected game. Choose the correct fix.")
                                .foregroundStyle(.red)
                        }
                        Text("\(package.entries.count) files ready. DLL settings will be configured automatically.")
                            .font(.callout)
                        DisclosureGroup("Advanced · files and DLL settings") {
                        Section("Files to install · \(package.entries.count)") {
                            Text("Paths are relative to the selected game folder. Existing files will be backed up.")
                                .font(.caption).foregroundStyle(.secondary)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 3) {
                                    ForEach(package.entries, id: \.path) { entry in
                                        Text(entry.path).font(.system(.caption, design: .monospaced))
                                    }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.frame(height: 100)
                        }
                        Section("DLL libraries · prefer native, then Wine") {
                            HStack {
                                Button("Recommended") { nativeDLLs = Set(package.recommendedDLLs) }
                                Button("Native All") { nativeDLLs = Set(package.dlls) }
                                Button("Clear") { nativeDLLs = [] }
                            }
                            ForEach(package.dlls, id: \.self) { dll in
                                Toggle(dll, isOn: Binding(get: { nativeDLLs.contains(dll) }, set: { enabled in
                                    if enabled { nativeDLLs.insert(dll) } else { nativeDLLs.remove(dll) }
                                }))
                            }
                            Text("Recommended selects package DLLs that also exist in CrossOver/Wine. Other DLLs are normally loaded by the game or the package's loader. Missing native DLLs can fall back to Wine; DLLs are not preloaded. Steam bridge DLLs are excluded.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        }
                    }
                }
                if step == 2 && receipt == nil, let package, let game = chosenGame {
                    Section("Ready to install") {
                        GameArtwork(game: game).frame(height: 150).clipShape(RoundedRectangle(cornerRadius: 8))
                        Text(game.name).font(.headline)
                        Text(archive?.lastPathComponent ?? "Custom fix")
                        Text("\(package.entries.count) files · Backup and DLL setup included")
                            .font(.callout).foregroundStyle(.secondary)
                        if let destination { Text(destination.path).font(.caption).textSelection(.enabled) }
                    }
                }
                if receipt != nil {
                    if !dllSettingsApplied {
                        Button("Finish DLL Setup") { applyDLLSettings() }
                            .disabled(selectedExecutable.isEmpty || (receipt?.nativeDLLs ?? []).isEmpty)
                    } else {
                        Label("DLL settings saved", systemImage: "checkmark.circle")
                    }
                    DisclosureGroup("Advanced · repair and manual options") {
                    Section("3 · NotProton DLL settings") {
                        Text("Saves native-then-builtin overrides for this game's EXE in its own Wine prefix, like Wine Configuration → Libraries. Other executables keep their existing settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        if dllSettingsApplied {
                            Label("DLL settings saved. Restore also restores previous DLL values.", systemImage: "checkmark.circle")
                        }
                        Button(dllSettingsApplied ? "Repair DLL Settings & Overlay" : "Apply DLL Settings to NotProton") { applyDLLSettings() }
                            .disabled(receipt == nil || selectedExecutable.isEmpty || (receipt?.nativeDLLs ?? Array(nativeDLLs)).isEmpty)
                        if !dllSettingsApplied {
                            Text("Install the files first. If no DLLs are recommended, the package may rely on its own loader; select additional overrides only when required.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Remove any previous WINEDLLOVERRIDES entry from Steam launch options before trying the registry settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup("Manual launch options (optional)") {
                            Text(options).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                            Button("Copy Launch Options") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(options, forType: .string)
                                message = "Manual launch options copied."
                            }
                        }
                    }
                    }
                }
            }.formStyle(.grouped)
            if busy { ProgressView().controlSize(.small) }
            if !message.isEmpty { Text(message).font(.callout).foregroundStyle(.secondary) }
            HStack {
                Button("Close", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if receipt == nil {
                    if step > 0 { Button("Back") { step -= 1 } }
                    Button(step == 2 ? "Install Custom Fix" : "Next") {
                        if step < 2 { step += 1 } else { install() }
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canContinue)
                }
                if receipt != nil || (initialGame != nil && initialGame?.id == validAppID) {
                    Button("Remove Custom Patch", role: .destructive) { remove() }
                        .disabled(locating)
                }
            }
            }
        }
        .padding(24).frame(width: 640, height: 720)
        .disabled(busy)
        .interactiveDismissDisabled(busy)
        .onAppear {
            if let game = initialGame {
                chooseGame(game)
            }
        }
        .onChange(of: selectedID) { _, id in
            if let game = library.first(where: { $0.id == id }) { chooseGame(game) }
        }
        .onChange(of: gameQuery) { _, query in
            if let game = chosenGame, query != game.name { chosenGame = nil; selectedID = 0 }
        }
        .task(id: gameQuery) { await searchGames() }
        .onChange(of: validAppID) { _, _ in
            clearTarget()
            directory = nil
            locating = false
            locationMessage = "Choose an installed game or enter its Steam AppID first."
        }
        .task(id: validAppID) {
            guard let id = validAppID, receipt == nil else { return }
            do {
                try await Task.sleep(for: .milliseconds(350))
                guard directory == nil, receipt == nil else { return }
                if initialGame?.id == id, let folder = initialGame?.installDirectory {
                    if directory == nil { selectDirectory(folder) }
                    return
                }
                if let folder = library.first(where: { $0.id == id })?.installDirectory {
                    if directory != folder { selectDirectory(folder) }
                    return
                }
                let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
                let installed = try await Task.detached { try SteamLibrary.scan(root: root) }.value
                try Task.checkCancellation()
                guard directory == nil else { return }
                if let folder = installed.first(where: { $0.id == id })?.installDirectory { selectDirectory(folder) }
                else {
                    clearTarget()
                    directory = nil
                    locationMessage = "This AppID was not found in the Steam library. Choose its game folder manually."
                }
            } catch is CancellationError { }
            catch { locationMessage = "Could not scan Steam. Choose the game folder manually." }
        }
        .onDisappear { package?.discard() }
        .alert("Custom Fix", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose the Windows game folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { selectDirectory(url) }
    }

    private func selectDirectory(_ url: URL) {
        let folder = url.resolvingSymlinksInPath().standardizedFileURL
        clearTarget()
        directory = folder
        message = ""
        locating = true
        Task {
            do {
                let record = try CustomFix.receipt(in: folder)
                receipt = record
                try WineDLLSettings.keepBackupOutsideGame(directory: folder)
                dllSettingsApplied = WineDLLSettings.hasBackup(directory: folder)
                guard FileManager.default.fileExists(atPath: folder.path) else {
                    locationMessage = "The game folder no longer exists. Remove Custom Patch will restore DLL settings only."
                    locating = false
                    return
                }
                let found = try await Task.detached { try SteamLibrary.windowsExecutables(in: folder) }.value
                guard directory == folder else { return }
                receipt = record
                executables = found
                selectedExecutable = found.first(where: {
                    URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent.caseInsensitiveCompare(chosenGame?.name ?? "") == .orderedSame
                }) ?? found.first(where: { !$0.lowercased().contains("crashhandler") }) ?? found.first ?? ""
                locationMessage = found.isEmpty
                    ? "No Windows .exe found. Select the Windows installation used by NotProton."
                    : "Game files found. The fix will be installed into this game folder."
            } catch {
                guard directory == folder else { return }
                self.error = error.localizedDescription
            }
            if directory == folder { locating = false }
        }
    }

    private func clearTarget() {
        package?.discard()
        package = nil
        archive = nil
        receipt = nil
        dllSettingsApplied = false
        executables = []
        selectedExecutable = ""
        useGameRoot = false
        needsPassword = false
        password = ""
    }

    private func chooseArchive() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "zip")!, UTType(filenameExtension: "rar") ?? .archive]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        package?.discard()
        package = nil
        archive = url
        needsPassword = false
        password = ""
        message = ""
        prepare(password: CustomFix.defaultPassword)
    }

    private func prepare(password: String) {
        guard let archive, let resources = Bundle.main.resourceURL else { return }
        let archiver = resources.appendingPathComponent("7zz")
        busy = true
        InstallationActivity.busy = true
        Task {
            defer { busy = false; InstallationActivity.busy = false }
            do {
                let prepared = try await Task.detached { try CustomFix.prepare(archive: archive, password: password, archiver: archiver) }.value
                package?.discard()
                package = prepared
                nativeDLLs = Set(prepared.recommendedDLLs)
                needsPassword = false
                self.password = ""
                message = "Archive ready. Review the files and DLL overrides before installing."
            } catch CustomFix.ArchiveError.password {
                needsPassword = true
                message = "Password rejected. Enter another password and retry."
            } catch { self.error = error.localizedDescription }
        }
    }

    private func install() {
        guard let package, let directory = destination, let chosenGame, validAppID != nil, packageMatchesGame else { return }
        let dlls = Array(nativeDLLs)
        let executable = directory == self.directory ? selectedExecutable : URL(fileURLWithPath: selectedExecutable).lastPathComponent
        busy = true
        InstallationActivity.busy = true
        Task {
            defer { busy = false; InstallationActivity.busy = false }
            do {
                try await Task.detached { try CustomFix.install(package, directory: directory, nativeDLLs: dlls, executable: executable) }.value
                receipt = try CustomFix.receipt(in: directory)
                self.directory = directory
                package.discard()
                self.package = nil
                message = "Files installed. Configuring DLL settings…"
                if let id = validAppID {
                    var game = ManagedGame(id: id, name: chosenGame.name, imageURL: chosenGame.imageURL)
                    game.installDirectory = directory
                    do { try onRemember(game) }
                    catch { self.error = "Files were installed, but the cover card could not be saved. Reopen the same game folder to restore.\n\(error.localizedDescription)" }
                    if !dlls.isEmpty {
                        let executable = URL(fileURLWithPath: selectedExecutable).lastPathComponent
                        try await Task.detached {
                            let prefix = try WineDLLSettings.prefix(appID: id, directory: directory)
                            try WineDLLSettings.apply(directory: directory, prefix: prefix, executable: executable, dlls: dlls)
                        }.value
                    }
                    dllSettingsApplied = true
                    message = "Custom fix installed. Start the game manually from Steam. Remove any old WINEDLLOVERRIDES launch option."
                }
            } catch {
                receipt = try? CustomFix.receipt(in: directory)
                if receipt != nil { self.directory = directory }
                if receipt != nil { message = "Files installed. Finish DLL Setup or Remove Custom Patch before trying again." }
                self.error = error.localizedDescription
            }
        }
    }

    private func remove() {
        guard let directory, let id = validAppID else { return }
        let target = receipt == nil && initialGame?.id == id ? initialGame?.installDirectory ?? directory : directory
        busy = true
        InstallationActivity.busy = true
        Task {
            defer { busy = false; InstallationActivity.busy = false }
            do {
                try await Task.detached {
                    try CustomFix.remove(directory: target)
                }.value
                receipt = nil
                dllSettingsApplied = false
                try onRemove(id)
                dismiss()
            } catch { self.error = error.localizedDescription }
        }
    }

    private func applyDLLSettings() {
        guard let directory = destination, let id = validAppID, let receipt, !selectedExecutable.isEmpty else { return }
        let executable = URL(fileURLWithPath: selectedExecutable).lastPathComponent
        let dlls = receipt.nativeDLLs
        busy = true
        InstallationActivity.busy = true
        Task {
            defer { busy = false; InstallationActivity.busy = false }
            do {
                try await Task.detached {
                    let prefix = try WineDLLSettings.prefix(appID: id, directory: directory)
                    try WineDLLSettings.apply(directory: directory, prefix: prefix, executable: executable, dlls: dlls)
                }.value
                dllSettingsApplied = true
                message = "DLL settings saved and known overlay dependencies checked for \(executable). Remove old WINEDLLOVERRIDES launch options, then start the game manually."
            } catch { self.error = error.localizedDescription }
        }
    }

    private func chooseGame(_ game: ManagedGame) {
        chosenGame = game
        gameQuery = game.name
        selectedID = library.contains(where: { $0.id == game.id }) ? game.id : 0
        storeResults = []
    }

    private func searchGames() async {
        storeResults = []
        searchError = nil
        searching = false
        let term = gameQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard chosenGame == nil, term.count >= 3, UInt32(term) == nil else { return }
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
                searchError = "Steam search is unavailable. Select an installed game or enter its AppID."
            }
        }
    }
}
