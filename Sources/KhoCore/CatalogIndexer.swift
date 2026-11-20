import Darwin
import Foundation

/// Walks the Kho into catalog rows; paths are relative to the Kho root.
public enum CatalogIndexer {
    static let skipped: Set<String> = [".Spotlight-V100", ".fseventsd", ".Trashes", ".DocumentRevisions-V100",
                                       ".TemporaryItems", ".DS_Store"]

    /// App data running from the Kho changes constantly and is not something to search.
    static let excludedRel = "SwitchKho/Live"

    static func isExcluded(_ rel: String) -> Bool { rel == excludedRel || rel.hasPrefix(excludedRel + "/") }

    static func isSkipped(_ name: String) -> Bool {
        skipped.contains(name) || name.hasPrefix(".switchkho-partial-") || name.hasPrefix(".ledger-backup.tmp-")
    }

    /// The whole volume. Stays on the volume's own device and never follows symlinks. Throws
    /// `khoOffline` when the root cannot be read, so a vanished Kho never looks empty.
    public static func scan(khoRoot: URL, progress: @Sendable (Int) -> Void = { _ in },
                            isCancelled: @Sendable () -> Bool = { false }) throws -> [CatalogItem] {
        var st = stat()
        guard lstat(khoRoot.path, &st) == 0,
              (try? FileManager.default.contentsOfDirectory(atPath: khoRoot.path)) != nil
        else { throw KhoError.khoOffline }
        var out: [CatalogItem] = []
        try walk(khoRoot, khoRoot: khoRoot, into: &out, progress: progress, isCancelled: isCancelled)
        return out
    }

    /// `root` itself and everything below it, for updates after an offload.
    public static func scanSubtree(root: URL, khoRoot: URL) -> [CatalogItem] {
        var out: [CatalogItem] = []
        guard let item = item(root, khoRoot: khoRoot), !isExcluded(item.relPath) else { return [] }
        out.append(item)
        var st = stat()
        if lstat(root.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR {
            try? walk(root, khoRoot: khoRoot, into: &out, progress: { _ in }, isCancelled: { false })
        }
        return out
    }

    static func item(_ url: URL, khoRoot: URL) -> CatalogItem? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let kind = st.st_mode & S_IFMT
        guard kind == S_IFDIR || kind == S_IFREG else { return nil }
        let rootCount = FileOps.components(khoRoot.path).count
        let rel = FileOps.components(url.path).dropFirst(rootCount).joined(separator: "/")
        guard !rel.isEmpty else { return nil }
        let modified = Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
        return CatalogItem(relPath: rel, name: url.lastPathComponent, size: kind == S_IFREG ? Int64(st.st_size) : 0,
                           isDirectory: kind == S_IFDIR, modified: modified)
    }

    static func walk(_ dir: URL, khoRoot: URL, into out: inout [CatalogItem],
                     progress: @Sendable (Int) -> Void, isCancelled: @Sendable () -> Bool) throws {
        var rootSt = stat()
        guard lstat(khoRoot.path, &rootSt) == 0 else { return }
        var stack = [dir]
        while let current = stack.popLast() {
            if isCancelled() { throw CancellationError() }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: current.path) else { continue }
            for name in names where !isSkipped(name) {
                let url = current.appendingPathComponent(name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                let kind = st.st_mode & S_IFMT
                if kind == S_IFDIR && st.st_dev != rootSt.st_dev { continue }
                guard let row = item(url, khoRoot: khoRoot), !isExcluded(row.relPath) else { continue }
                out.append(row)
                if kind == S_IFDIR { stack.append(url) }
                if out.count % 10_000 == 0 { progress(out.count) }
            }
        }
        progress(out.count)
    }
}
