import Foundation
import Security

/// A drive counts as the Kho only when its UUID matches and `SwitchKho/.kho-id` holds the
/// secret token saved in the ledger. The mount path does not matter.
public enum KhoIdentity {
    static func tokenFile(_ root: URL) -> URL { root.appendingPathComponent("SwitchKho/.kho-id") }

    static func readToken(_ root: URL) -> String? {
        guard let data = try? Data(contentsOf: tokenFile(root)) else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func confirm(volumes: [VolumeInfo], savedUUID: String?, savedToken: String?,
                               linkRoot: URL) -> MountedKho? {
        guard let savedUUID, let savedToken, !savedToken.isEmpty,
              let v = volumes.first(where: { $0.uuid == savedUUID }),
              !v.isDiskImage, v.isAPFS, readToken(v.url) == savedToken
        else { return nil }
        return MountedKho(uuid: savedUUID, layout: KhoLayout(khoRoot: v.url, linkRoot: linkRoot))
    }

    public static func mismatchReason(volumes: [VolumeInfo], savedUUID: String?, savedToken: String?) -> String? {
        guard let savedUUID else { return nil }
        if let v = volumes.first(where: { $0.uuid == savedUUID }) {
            if v.isDiskImage || !v.isAPFS { return "Ổ này không phải ổ APFS thật" }
            if readToken(v.url) != savedToken { return "Ổ này không có dấu nhận Kho hợp lệ" }
            return nil
        }
        if volumes.contains(where: { $0.name == "Kho" }) { return "Ổ tên Kho này không phải Kho đã chọn" }
        return nil
    }

    /// Makes `volume` the Kho. Reuses an existing token (a drive that was the Kho before),
    /// otherwise writes a new random one. Call only after the user confirmed.
    public static func adopt(_ volume: VolumeInfo, linkRoot: URL) throws -> (MountedKho, token: String) {
        guard let uuid = volume.uuid, !volume.isDiskImage else {
            throw KhoError.invalidState("Ổ này không dùng làm Kho được")
        }
        let token: String
        if let existing = readToken(volume.url), existing.count == 64 {
            token = existing
        } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw KhoError.io("Không sinh được mã nhận Kho")
            }
            token = bytes.map { String(format: "%02x", $0) }.joined()
            let file = tokenFile(volume.url)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data(token.utf8).write(to: file, options: .atomic)
        }
        return (MountedKho(uuid: uuid, layout: KhoLayout(khoRoot: volume.url, linkRoot: linkRoot)), token)
    }

    public static func hasLedgerBackup(_ volume: VolumeInfo) -> Bool {
        FileManager.default.fileExists(atPath: volume.url.appendingPathComponent("SwitchKho/ledger-backup.sqlite").path)
    }
}
