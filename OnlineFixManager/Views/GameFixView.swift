import SwiftUI

struct GameFixView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: ManagedGame
    @ViewState private var phasmEnabled: Bool
    @ViewState private var phasmAppID: String
    @ViewState private var repoEnabled: Bool
    let game: ManagedGame
    let supportsNativePatch: Bool
    let onSave: (ManagedGame) -> Bool

    init(game: ManagedGame, supportsNativePatch: Bool, onSave: @escaping (ManagedGame) -> Bool) {
        var initial = game
        if game.id == 3241660 && game.repoPhoton.realtime.isEmpty {
            initial.repoPhoton.realtime = PhotonServers.all.first?.appID ?? ""
        }
        _draft = ViewState(initialValue: initial)
        _repoEnabled = ViewState(initialValue: !game.repoPhoton.isEmpty)
        _phasmEnabled = ViewState(initialValue: !game.phasmophobiaPhotonAppID.isEmpty)
        _phasmAppID = ViewState(initialValue: game.phasmophobiaPhotonAppID.lowercased())
        self.game = game
        self.supportsNativePatch = supportsNativePatch
        self.onSave = onSave
    }

    private var repoIDs: RepoPhotonIDs {
        RepoPhotonIDs(realtime: draft.repoPhoton.realtime.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                      voice: draft.repoPhoton.voice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Fix").font(.title2.bold())
                Text("\(draft.name) · AppID \(String(draft.id))").foregroundStyle(.secondary)
            }
            Form {
                if !game.fileFixInstalled {
                    Label("Install the game, then refresh your library.", systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if draft.id == 105600 || draft.id == 2644470 {
                    Section("Game file fix") {
                        if draft.id == 105600 {
                            Toggle("Server environment fix", isOn: $draft.patches.terrariaServerEnvironment)
                                .disabled(!supportsNativePatch)
                            Text("Native macOS only. Fixes server startup. Disabling restores the backup.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Toggle("Photon compatibility fix", isOn: $draft.picoPark2Photon)
                                .disabled(!supportsNativePatch)
                            Text("Apple Silicon macOS only. Quit the game before saving. Disabling restores backups.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if draft.id == 3241660 {
                    Section("R.E.P.O. · Windows / NotProton") {
                        Toggle("Experimental Photon file patch", isOn: $repoEnabled)
                            .disabled(!game.fileFixInstalled)
                        Picker("Server", selection: $draft.repoPhoton.realtime) {
                            Text("Choose a server").tag("")
                            ForEach(PhotonServers.all, id: \.appID) { server in
                                Text(server.name).tag(server.appID)
                            }
                            if !draft.repoPhoton.realtime.isEmpty && !PhotonServers.all.contains(where: { $0.appID == draft.repoPhoton.realtime }) {
                                Text("Previously configured server").tag(draft.repoPhoton.realtime)
                            }
                        }
                        .disabled(!repoEnabled || !game.fileFixInstalled)
                        Picker("Voice server", selection: $draft.repoPhoton.voice) {
                            Text("Original voice server").tag("")
                            ForEach(PhotonServers.voiceServers.filter { !$0.appID.isEmpty }, id: \.appID) { server in
                                Text(server.name).tag(server.appID)
                            }
                            if !draft.repoPhoton.voice.isEmpty && !PhotonServers.voiceServers.contains(where: { $0.appID == draft.repoPhoton.voice }) {
                                Text("Previously configured server").tag(draft.repoPhoton.voice)
                            }
                        }
                        .disabled(!repoEnabled || !game.fileFixInstalled)
                        Text("Use the same servers, region and game version. Multiplayer and voice untested.")
                            .font(.caption).foregroundStyle(.secondary)
                        if repoEnabled && !repoIDs.isValid {
                            Text("Choose a server.")
                                .font(.caption).foregroundStyle(.red)
                        }
                    }
                }
                if draft.id == 739630 {
                    Section("Phasmophobia · Windows / NotProton") {
                        Toggle("Experimental Photon file patch", isOn: $phasmEnabled)
                            .disabled(!game.fileFixInstalled)
                        Picker("Server", selection: $phasmAppID) {
                            Text("Choose a server").tag("")
                            ForEach(PhotonServers.all, id: \.appID) { server in
                                Text(server.name).tag(server.appID)
                            }
                            if !draft.phasmophobiaPhotonAppID.isEmpty && !PhotonServers.all.contains(where: { $0.appID == draft.phasmophobiaPhotonAppID.lowercased() }) {
                                Text("Previously configured server").tag(draft.phasmophobiaPhotonAppID.lowercased())
                            }
                        }
                        .disabled(!phasmEnabled || !game.fileFixInstalled)
                        if phasmEnabled && !PhasmophobiaPatch.validateAppID(phasmAppID.trimmingCharacters(in: .whitespacesAndNewlines)) {
                            Text("Choose a server.")
                                .font(.caption).foregroundStyle(.red)
                        }
                        Text("Use the same server. Other authentication checks may block multiplayer. Multiplayer untested.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.formStyle(.grouped)
            Text("Relaunch the game after saving.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Restore Defaults") { draft.patches.terrariaServerEnvironment = false; draft.picoPark2Photon = false; phasmEnabled = false; phasmAppID = ""; repoEnabled = false }
                    .disabled(!game.fileFixInstalled)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    var updated = draft
                    updated.repoPhoton = repoEnabled ? repoIDs : RepoPhotonIDs()
                    updated.phasmophobiaPhotonAppID = phasmEnabled ? phasmAppID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() : ""
                    if onSave(updated) { dismiss() }
                }
                .disabled(!game.fileFixInstalled || (draft.id == 3241660 && repoEnabled && !repoIDs.isValid) || (draft.id == 739630 && phasmEnabled && !PhasmophobiaPatch.validateAppID(phasmAppID.trimmingCharacters(in: .whitespacesAndNewlines))))
                .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520, height: [739630, 3241660].contains(draft.id) ? 510 : 400)
    }
}
