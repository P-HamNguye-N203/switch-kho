import Darwin
import Foundation

/// `~/Library/Application Support/SwitchKho/KhoLink`: a symlink to the confirmed Kho's
/// `SwitchKho` folder that exists only while that Kho is mounted.
public enum KhoLink {
    public static func update(linkRoot: URL, kho: MountedKho?) throws {
        let exists = FileOps.exists(linkRoot)
        if exists, !FileOps.isSymlink(linkRoot) {
            throw KhoError.invalidState("KhoLink là một thư mục thật, không gỡ: \(linkRoot.path)")
        }
        guard let kho else {
            if exists, unlink(linkRoot.path) != 0 {
                throw KhoError.io("Không gỡ được KhoLink: \(String(cString: strerror(errno)))")
            }
            return
        }
        let target = kho.layout.base.path
        if exists, (try? FileManager.default.destinationOfSymbolicLink(atPath: linkRoot.path)) == target { return }
        try FileManager.default.createDirectory(at: linkRoot.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let tmp = linkRoot.deletingLastPathComponent().appendingPathComponent(".KhoLink-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(atPath: tmp.path, withDestinationPath: target)
        guard rename(tmp.path, linkRoot.path) == 0 else {
            _ = unlink(tmp.path)
            throw KhoError.io("Không cập nhật được KhoLink: \(String(cString: strerror(errno)))")
        }
    }
}
