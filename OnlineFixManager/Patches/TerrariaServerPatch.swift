import Darwin
import Foundation

enum TerrariaServerPatch {
    static func setEnabled(_ enabled: Bool, launcher: URL) throws {
        let result = launcher.path.withCString { of_terraria_server_patch($0, enabled) }
        guard result != 0 else { return }
        let detail: String
        switch result {
        case ESTALE: detail = "Launcher or backup mismatch. Keep the .onlinefix-backup file for recovery."
        case ENOTSUP: detail = "Unsupported Terraria server launcher. Fix requires MonoKickstart."
        case ENOENT: detail = "Server launcher is missing. Verify the installation in Steam."
        default: detail = String(cString: strerror(result))
        }
        throw ManagerError(message: "Terraria server environment fix: \(detail)")
    }
}
