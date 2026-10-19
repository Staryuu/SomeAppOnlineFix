import Darwin
import Foundation

enum RepoPatch {
    private static func check(_ code: Int32) throws {
        guard code != 0 else { return }
        let detail: String
        switch code {
        case ENOENT: detail = "Required game files are missing. Verify the installation in Steam."
        case ENOTSUP: detail = "Game file hashes or structure do not match this fix. Patch blocked."
        case ESTALE: detail = "Game files or backups do not match. Keep the REPO.onlinefix-repo-*.backup file for recovery."
        case EINVAL: detail = "Use valid, distinct Photon App IDs. Voice is optional."
        case EWOULDBLOCK: detail = "Another R.E.P.O. patch operation is running."
        default: detail = String(cString: strerror(code))
        }
        throw ManagerError(message: "R.E.P.O. Photon patch: \(detail)")
    }

    static func appIDs(directory: URL) throws -> RepoPhotonIDs {
        var pun = [CChar](repeating: 0, count: 37)
        var voice = [CChar](repeating: 0, count: 37)
        try check(directory.path.withCString { of_repo_status($0, &pun, &voice) })
        return RepoPhotonIDs(
            realtime: String(decoding: pun.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self),
            voice: String(decoding: voice.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    static func setAppIDs(_ ids: RepoPhotonIDs, directory: URL) throws {
        guard ids.isEmpty || ids.isValid else { try check(EINVAL); return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = ["-if", "[Rr][Ee][Pp][Oo][.]exe"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 1 else {
            throw ManagerError(message: process.terminationStatus == 0
                ? "Quit R.E.P.O. first."
                : "Cannot check if R.E.P.O. is running. Patch blocked.")
        }
        try check(directory.path.withCString { directory in
            ids.realtime.withCString { pun in
                ids.voice.withCString { voice in of_repo_patch(directory, pun, voice, !ids.isEmpty) }
            }
        })
    }
}
