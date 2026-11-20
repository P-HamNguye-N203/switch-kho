import Foundation
import KhoCore
import ServiceManagement

/// `--selftest`: checks this app's own permissions without starting the app proper (no
/// instance lock, no ledger writes, no recovery), writes `selftest.json` and exits. Must be
/// launched through Launch Services (`open -n -W … --args --selftest`) so the result reflects
/// the app's permissions, not those of Terminal.
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }

    @MainActor
    static func runAndExit() -> Never {
        let dataDir = AppModel.dataDirectory()
        let home = FileManager.default.homeDirectoryForCurrentUser
        let fda = (try? FileManager.default.contentsOfDirectory(atPath: home.appendingPathComponent("Library/Safari").path)) != nil
        let settings = (try? Ledger.readSettings(path: dataDir.appendingPathComponent("ledger.sqlite"),
                                                keys: ["kho.uuid", "kho.token"])) ?? [:]
        let kho = KhoIdentity.confirm(volumes: VolumeService.mountedVolumes(), savedUUID: settings["kho.uuid"],
                                      savedToken: settings["kho.token"],
                                      linkRoot: dataDir.appendingPathComponent("KhoLink")) != nil
        let result: [String: Any] = [
            "fda": fda, "loginItem": loginItemStatus(), "kho": kho,
            "at": ISO8601DateFormatter().string(from: Date()),
        ]
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: dataDir.appendingPathComponent("selftest.json"), options: .atomic)
        }
        exit(0)
    }

    /// Spelled out: `String(describing:)` prints "SMAppServiceStatus(rawValue: 1)".
    static func loginItemStatus() -> String {
        let status = SMAppService.mainApp.status
        switch status {
        case .enabled: return "enabled"
        case .requiresApproval: return "requiresApproval"
        case .notRegistered: return "notRegistered"
        case .notFound: return "notFound"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }
}
