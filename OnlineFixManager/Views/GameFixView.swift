import SwiftUI

struct GameFixView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: ManagedGame
    @ViewState private var phasmEnabled: Bool
    @ViewState private var phasmAppID: String
    let game: ManagedGame
    let supportsNativePatch: Bool
    let onSave: (ManagedGame) -> Bool

    init(game: ManagedGame, supportsNativePatch: Bool, onSave: @escaping (ManagedGame) -> Bool) {
        _draft = ViewState(initialValue: game)
        _phasmEnabled = ViewState(initialValue: !game.phasmophobiaPhotonAppID.isEmpty)
        _phasmAppID = ViewState(initialValue: game.phasmophobiaPhotonAppID.lowercased())
        self.game = game
        self.supportsNativePatch = supportsNativePatch
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Fix").font(.title2.bold())
                Text("\(draft.name) · AppID \(String(draft.id))").foregroundStyle(.secondary)
            }
            Form {
                if !game.fileFixInstalled {
                    Label("Install the supported game version, then refresh your library to apply this fix.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if draft.id == 105600 || draft.id == 2644470 {
                    Section("Game file fix") {
                        if draft.id == 105600 {
                            Toggle("Server environment fix", isOn: $draft.patches.terrariaServerEnvironment)
                                .disabled(!supportsNativePatch)
                            Text("Native macOS only. Updates the server launcher to keep Steam injection out of shell helpers. Keeps a backup; disabling restores it.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Toggle("Photon compatibility fix", isOn: $draft.picoPark2Photon)
                                .disabled(!supportsNativePatch)
                            Text("Native macOS only, for the supported Apple Silicon build. Quit PICO PARK 2 before saving. Keeps backups; disabling restores the original files.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if draft.id == 739630 {
                    Section("Phasmophobia · Windows / NotProton") {
                        Toggle("Experimental Photon file patch", isOn: $phasmEnabled)
                            .disabled(!game.fileFixInstalled)
                        Picker("Server", selection: $phasmAppID) {
                            Text("Choose a server").tag("")
                            ForEach(PhasmophobiaPatch.servers, id: \.appID) { server in
                                Text(server.name).tag(server.appID)
                            }
                            if !draft.phasmophobiaPhotonAppID.isEmpty && !PhasmophobiaPatch.servers.contains(where: { $0.appID == draft.phasmophobiaPhotonAppID.lowercased() }) {
                                Text("Previously configured server").tag(draft.phasmophobiaPhotonAppID.lowercased())
                            }
                        }
                        .disabled(!phasmEnabled || !game.fileFixInstalled)
                        if phasmEnabled && !PhasmophobiaPatch.validateAppID(phasmAppID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Text("Choose a server to enable Save.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        Text("Players must choose the same server. Launcher reservation and Unity Services authentication are separate; multiplayer compatibility is untested.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            Text("Changes apply to this game’s files. Relaunch it after saving.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Restore Defaults") { draft.patches.terrariaServerEnvironment = false; draft.picoPark2Photon = false; phasmEnabled = false; phasmAppID = "" }
                    .disabled(!game.fileFixInstalled)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = draft
                    updated.phasmophobiaPhotonAppID = phasmEnabled ? phasmAppID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
                    if onSave(updated) { dismiss() }
                }
                .disabled(!game.fileFixInstalled || (draft.id == 739630 && phasmEnabled && !PhasmophobiaPatch.validateAppID(phasmAppID.trimmingCharacters(in: .whitespacesAndNewlines))))
                .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520, height: draft.id == 739630 ? 510 : 400)
    }
}
