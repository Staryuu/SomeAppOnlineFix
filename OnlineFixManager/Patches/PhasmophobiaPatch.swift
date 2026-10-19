import Darwin
import Foundation

enum PhasmophobiaPatch {
    static func validateAppID(_ value: String) -> Bool {
        value.utf8.count == 36 && UUID(uuidString: value) != nil
            && value.lowercased() != "80449c66-0a91-49a5-acb6-ca805e84e605"
    }

    private static func check(_ result: Int32) throws {
        guard result != 0 else { return }
        let detail: String
        switch result {
        case ENOENT: detail = "Required game files are missing. Verify the installation in Steam."
        case ENOTSUP: detail = "Game file hashes or structure do not match this fix. Patch blocked."
        case ESTALE: detail = "Game files or backups do not match. Keep all Phasmophobia patch backups for recovery."
        case EINVAL: detail = "Enter a replacement Photon App ID (GUID)."
        case EWOULDBLOCK: detail = "Another Phasmophobia patch operation is running."
        default: detail = String(cString: strerror(result))
        }
        throw ManagerError(message: "Phasmophobia Photon patch: \(detail)")
    }

    static func appID(directory: URL) throws -> String {
        var value = [CChar](repeating: 0, count: 37)
        try check(directory.path.withCString { of_phasmophobia_status($0, &value) })
        return String(decoding: value.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    static func setAppID(_ value: String, directory: URL) throws {
        guard value.isEmpty || validateAppID(value) else { try check(EINVAL); return }
        // Wine processes may not appear in NSRunningApplication.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-if", "[P]hasmophobia[.]exe"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 1 else {
            throw ManagerError(message: process.terminationStatus == 0
                ? "Quit Phasmophobia first."
                : "Cannot check if Phasmophobia is running. Patch blocked.")
        }
        try check(directory.path.withCString { path in
            value.withCString { of_phasmophobia_patch(path, $0, !value.isEmpty) }
        })
    }
}
