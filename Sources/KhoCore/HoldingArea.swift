import Darwin
import Foundation

/// Where originals wait (same volume, instant rename) until an operation is committed.
/// Slots are named after the operation `uid` and end in `.held`, so a held `.app` is no
/// longer an app and Launch Services will not open it.
public struct HoldingArea: Sendable {
    public let root: URL
    let beforeRename: (@Sendable (URL) throws -> Void)?

    public static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SwitchKho/Holding")
    }

    public init(root: URL = HoldingArea.defaultRoot, beforeRename: (@Sendable (URL) throws -> Void)? = nil) {
        self.root = root
        self.beforeRename = beforeRename
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        _ = chmod(root.path, 0o700)
    }

    public func slotURL(opUID: String, index: Int, original: URL) -> URL {
        root.appendingPathComponent(opUID).appendingPathComponent("\(index)-\(original.lastPathComponent).held")
    }

    /// Moves `original` into `slot`. The caller records `slot` in the ledger first.
    public func hold(_ original: URL, to slot: URL) throws {
        let dir = slot.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        _ = chmod(dir.path, 0o700)
        _ = chmod(root.path, 0o700)
        try beforeRename?(original)
        guard renamex_np(original.path, slot.path, UInt32(RENAME_EXCL)) == 0 else {
            let err = errno
            if err == EXDEV { throw KhoError.io("Vùng chờ phải cùng ổ với bản gốc") }
            if err == EEXIST { throw KhoError.destinationOccupied(slot.path) }
            if err == ENOENT { throw KhoError.notFound(original.path) }
            if err == EPERM || err == EACCES { throw KhoError.notDeletable(original.path) }
            throw KhoError.io("Không dời được vào vùng chờ \(original.path): \(String(cString: strerror(err)))")
        }
    }

    /// `<name> (<suffix>)`, `<name> (<suffix> 2)`, … beside `original`, keeping the extension.
    static func siblingCandidates(_ original: URL, suffix: String) -> [URL] {
        let dir = original.deletingLastPathComponent()
        let ext = original.pathExtension
        let stem = ext.isEmpty ? original.lastPathComponent : original.deletingPathExtension().lastPathComponent
        return (1...99).map { n in
            let label = n == 1 ? "\(stem) (\(suffix))" : "\(stem) (\(suffix) \(n))"
            return dir.appendingPathComponent(ext.isEmpty ? label : "\(label).\(ext)")
        }
    }

    /// Moves `held` back to `original`, or to a free sibling name when `original` is taken.
    /// Never deletes anything at `original`. Idempotent: when `held` is already gone, finds
    /// the item with `expectedIno` at `original` or a sibling and returns that path.
    @discardableResult
    public func release(_ held: URL, to original: URL, expectedIno: UInt64?,
                        suffix: String = "khôi phục") throws -> URL {
        let candidates = [original] + Self.siblingCandidates(original, suffix: suffix)
        guard FileOps.exists(held) else {
            if let expectedIno, let found = candidates.first(where: { FileOps.inode($0) == expectedIno }) {
                return found
            }
            throw KhoError.invalidState("Không tìm thấy bản trong vùng chờ")
        }
        try FileManager.default.createDirectory(at: original.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        for target in candidates where !FileOps.exists(target) {
            if renamex_np(held.path, target.path, UInt32(RENAME_EXCL)) == 0 { return target }
            if errno != EEXIST {
                throw KhoError.io("Không trả được \(held.lastPathComponent): \(String(cString: strerror(errno)))")
            }
        }
        throw KhoError.destinationOccupied(original.path)
    }

    public func purge(opUID: String) throws {
        try FileOps.removeTree(root.appendingPathComponent(opUID))
    }

    public func pendingBytes() -> Int64 {
        var total: Int64 = 0
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                          options: [], errorHandler: { _, _ in true })
        else { return 0 }
        for case let url as URL in walker {
            var st = stat()
            if lstat(url.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG {
                total += Int64(st.st_blocks) * 512
            }
        }
        return total
    }

    public func slotDirectories() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { !$0.hasPrefix(".") }.sorted()
    }
}
