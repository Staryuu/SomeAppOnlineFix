import Darwin
import Foundation

enum TerrariaServerPatch {
    static func setEnabled(_ enabled: Bool, launcher: URL) throws {
        let result = launcher.path.withCString { of_terraria_server_patch($0, enabled) }
        guard result != 0 else { return }
        let detail: String
        switch result {
        case ESTALE: detail = "The server launcher or its backup changed. Nothing was overwritten. Keep the .onlinefix-backup file for recovery."
        case ENOTSUP: detail = "This is not a supported Terraria MonoKickstart server launcher."
        default: detail = String(cString: strerror(result))
        }
        throw ManagerError(message: "Terraria server environment fix: \(detail)")
    }
}
