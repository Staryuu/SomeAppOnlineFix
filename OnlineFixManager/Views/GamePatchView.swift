import SwiftUI

struct GamePatchView: View {
    @Environment(\.dismiss) private var dismiss
    @ViewState private var draft: ManagedGame
    let onSave: (ManagedGame) -> Bool

    init(game: ManagedGame, onSave: @escaping (ManagedGame) -> Bool) {
        _draft = ViewState(initialValue: game)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Patch").font(.title2.bold())
                Text("\(draft.name) · AppID \(String(draft.id))").foregroundStyle(.secondary)
            }
            Form {
                Section("AppID reporting") {
                    Toggle("Keep real AppID", isOn: $draft.keepRealAppID)
                        .help("Always report the real game ID. Matchmaking still uses 480.")
                    Toggle("Restore AppID at startup", isOn: $draft.patches.startupAppID)
                        .disabled(draft.keepRealAppID)
                        .help("Report the real game ID until networking starts. Keep real AppID overrides this setting.")
                }
                Section("Compatibility patches") {
                    Toggle("Restore overlay AppID", isOn: $draft.patches.overlayAppID)
                        .help("Use the original game ID for the Steam overlay.")
                    Toggle("Restore Steam Input AppID", isOn: $draft.patches.inputAppID)
                        .help("Use the game's own controller configuration.")
                    Toggle("Restore stats callback AppID", isOn: $draft.patches.statsAppID)
                        .help("Report the original game ID in UserStatsReceived callbacks.")
                }
            }.formStyle(.grouped)
            Text("Settings apply only to this game. Relaunch it after saving.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Restore Defaults") { draft.patches = PatchSettings(); draft.keepRealAppID = false }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { if onSave(draft) { dismiss() } }
                .keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 520, height: 490)
    }
}
