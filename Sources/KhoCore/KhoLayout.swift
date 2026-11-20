import Foundation

/// Where things live on the Kho volume. Archived items mirror their absolute original path,
/// so the original location is recoverable even without the database.
public struct KhoLayout: Sendable, Equatable {
    public let khoRoot: URL
    /// The "Kho link" (`~/Library/Application Support/SwitchKho/KhoLink`): a symlink to
    /// `base` that only exists while the confirmed Kho is mounted. Symlinks created by the
    /// app point through it instead of `/Volumes/Kho`.
    public let linkRoot: URL

    public init(khoRoot: URL, linkRoot: URL) {
        self.khoRoot = khoRoot
        self.linkRoot = linkRoot
    }

    public var base: URL { khoRoot.appendingPathComponent("SwitchKho", isDirectory: true) }
    public var archive: URL { base.appendingPathComponent("Archive", isDirectory: true) }
    public var apps: URL { base.appendingPathComponent("Apps", isDirectory: true) }
    public var live: URL { base.appendingPathComponent("Live", isDirectory: true) }
    public var ledgerBackup: URL { base.appendingPathComponent("ledger-backup.sqlite") }
    public var identityFile: URL { base.appendingPathComponent(".kho-id") }

    public func archiveURL(forOriginal original: URL) -> URL {
        var url = archive
        for part in FileOps.components(original.path) where !part.isEmpty {
            url.appendPathComponent(part)
        }
        return url
    }

    public func originalURL(forArchived url: URL) -> URL? {
        let a = FileOps.components(url.path).filter { !$0.isEmpty }
        let root = FileOps.components(archive.path).filter { !$0.isEmpty }
        guard a.count > root.count, FileOps.isUnder(url, archive) else { return nil }
        return URL(fileURLWithPath: "/" + a.dropFirst(root.count).joined(separator: "/"))
    }

    public func appBundleRoot(bundleID: String) -> URL { apps.appendingPathComponent(bundleID) }
    public func liveRoot(bundleID: String) -> URL { live.appendingPathComponent(bundleID) }

    /// Path relative to `khoRoot` (component-wise), e.g. `SwitchKho/Archive/Users/a/x`.
    public func relativePath(_ url: URL) -> String? {
        let a = FileOps.components(url.path).filter { !$0.isEmpty }
        let root = FileOps.components(khoRoot.path).filter { !$0.isEmpty }
        guard a.count > root.count, FileOps.isUnder(url, khoRoot) else { return nil }
        return a.dropFirst(root.count).joined(separator: "/")
    }

    /// Validated components of a ledger-supplied relative path. Only
    /// `SwitchKho/{Archive|Apps|Live}/<at least one more>` is accepted.
    func validatedComponents(_ relative: String) throws -> [String] {
        guard !relative.isEmpty, !relative.hasPrefix("/") else { throw KhoError.blocked(relative) }
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        if parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw KhoError.blocked(relative)
        }
        guard parts.count >= 3, parts[0] == "SwitchKho",
              ["Archive", "Apps", "Live"].contains(parts[1])
        else { throw KhoError.blocked(relative) }
        return parts
    }

    /// The only gate that turns a path read from the ledger into a path that may be deleted.
    public func absoluteURL(relative: String) throws -> URL {
        let parts = try validatedComponents(relative)
        var url = khoRoot
        for p in parts { url.appendPathComponent(p) }
        guard FileOps.isUnder(url, base), !FileOps.same(url, base) else {
            throw KhoError.blocked(relative)
        }
        return url
    }

    /// Symlink destination for a Kho-relative path, routed through the Kho link.
    public func symlinkTarget(relative: String) throws -> URL {
        let parts = try validatedComponents(relative)
        var url = linkRoot
        for p in parts.dropFirst() { url.appendPathComponent(p) }
        return url
    }

    public func isOurLinkTarget(_ target: URL) -> Bool {
        FileOps.isUnder(target, linkRoot) && !FileOps.same(target, linkRoot)
    }
}
