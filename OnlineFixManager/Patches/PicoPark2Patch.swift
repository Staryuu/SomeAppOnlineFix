import AppKit
import Darwin
import Foundation

enum PicoPark2Patch {
    private static func check(_ result: Int32) throws {
        guard result != 0 else { return }
        let detail: String
        switch result {
        case ENOENT: detail = "Required game files are missing. Verify the installation in Steam."
        case ENOTSUP: detail = "Game file hashes or structure do not match this fix. Patch blocked."
        case ESTALE: detail = "Game files or backups do not match. Keep both backups for recovery."
        case EWOULDBLOCK: detail = "Another PICO PARK 2 patch operation is running."
        case EIO: detail = "Writing or signing failed. Keep both backups for recovery."
        default: detail = String(cString: strerror(result))
        }
        throw ManagerError(message: "PICO PARK 2 Photon compatibility fix: \(detail)")
    }

    static func isEnabled(app: URL) throws -> Bool {
        var enabled = false
        try check(app.path.withCString { of_pico_park_2_status($0, &enabled) })
        return enabled
    }

    static func setEnabled(_ enabled: Bool, app: URL) throws {
        guard !NSRunningApplication.runningApplications(withBundleIdentifier: "com.tecopark.picopark2")
            .contains(where: { $0.bundleURL?.resolvingSymlinksInPath() == app.resolvingSymlinksInPath() }) else {
            throw ManagerError(message: "Quit PICO PARK 2 first.")
        }
        try check(app.path.withCString { of_pico_park_2_patch($0, enabled) })
    }
}
