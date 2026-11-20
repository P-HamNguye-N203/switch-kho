import Foundation

public enum PathPurpose: String, Sendable, Codable {
    case personal, appData, appBundle, trashContents, packageCache
}

/// Decides which paths an operation may touch, per purpose. Paths are canonicalised with
/// `realpath(3)` on the parent and compared component-wise and case-insensitively, so
/// symlinks, letter case and string prefixes cannot be used to escape the rules.
public struct PathPolicy: Sendable {
    public let home: URL
    public let applicationsDirs: [URL]
    public let protectedRoots: [URL]
    public let selfAppURL: URL?

    static let appDataAreas = [
        "Application Support", "Containers", "Group Containers", "Caches", "HTTPStorages",
        "WebKit", "Logs", "Saved Application State", "Developer", "pnpm",
    ]
    static let packageCacheDirs = [
        ".npm/_cacache", ".cache/huggingface", ".cache/pip", ".cache/uv", ".cache/pnpm",
    ]

    public init(home: URL, applicationsDirs: [URL], protectedRoots: [URL], selfAppURL: URL?) {
        self.home = FileOps.resolved(home)
        self.applicationsDirs = applicationsDirs.map(FileOps.resolved)
        self.protectedRoots = protectedRoots.map(FileOps.resolved)
        self.selfAppURL = selfAppURL.map(FileOps.resolved)
    }

    /// Policy for the real app.
    public static func live() -> PathPolicy {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let roots = ["/System", "/Library", "/usr", "/bin", "/sbin", "/private", "/etc", "/var",
                     "/opt", "/cores", "/dev", "/Volumes", "/tmp"].map { URL(fileURLWithPath: $0) }
        return PathPolicy(
            home: home,
            applicationsDirs: [URL(fileURLWithPath: "/Applications"),
                               home.appendingPathComponent("Applications")],
            protectedRoots: roots,
            selfAppURL: Bundle.main.bundleURL)
    }

    private var library: URL { home.appendingPathComponent("Library") }
    private var trash: URL { home.appendingPathComponent(".Trash") }
    private var ownData: URL {
        library.appendingPathComponent("Application Support").appendingPathComponent("SwitchKho")
    }

    /// Canonical form of `url`: the parent resolved with `realpath(3)`, the last component
    /// kept as is (the item itself may be a symlink). Throws `.blocked` for `..`, `.`, empty
    /// components, a missing parent, or a parent reached through a symlink.
    public func canonical(_ url: URL) throws -> URL {
        let path = url.path
        guard path.hasPrefix("/") else { throw KhoError.blocked(path) }
        let parts = FileOps.components(path)
        let trimmed = parts.last == "" ? Array(parts.dropLast()) : parts
        if trimmed.isEmpty { return URL(fileURLWithPath: "/") }
        if trimmed.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) {
            throw KhoError.blocked(path)
        }
        let name = trimmed.last!
        let textualParent = "/" + trimmed.dropLast().joined(separator: "/")
        guard let realParent = FileOps.realpath(textualParent) else {
            throw KhoError.blocked("Thư mục chứa không tồn tại: \(textualParent)")
        }
        let expected = Self.withPrivatePrefix(textualParent)
        if realParent.caseInsensitiveCompare(expected) != .orderedSame,
           realParent.caseInsensitiveCompare(textualParent) != .orderedSame
        {
            throw KhoError.blocked("Đường dẫn đi qua liên kết tượng trưng: \(path)")
        }
        return URL(fileURLWithPath: realParent).appendingPathComponent(name)
    }

    /// `/var`, `/tmp` and `/etc` are symlinks into `/private` on macOS.
    static func withPrivatePrefix(_ path: String) -> String {
        for top in ["/var", "/tmp", "/etc"] where path == top || path.hasPrefix(top + "/") {
            return "/private" + path
        }
        return path
    }

    public func isAllowed(_ url: URL, purpose: PathPurpose) -> Bool {
        (try? check(url, purpose: purpose)) != nil
    }

    public func check(_ url: URL, purpose: PathPurpose) throws {
        let c = try canonical(url)
        let shown = url.path
        let blocked = KhoError.blocked(shown)

        // Always blocked.
        if c.path == "/" || FileOps.same(c, home) || FileOps.same(c, library) { throw blocked }
        if FileOps.same(c.deletingLastPathComponent(), library) { throw blocked }
        if FileOps.same(c, trash) { throw blocked }
        if FileOps.isUnder(c, ownData) { throw blocked }
        if let selfApp = selfAppURL, FileOps.isUnder(c, selfApp) { throw blocked }
        if protectedRoots.contains(where: { FileOps.isUnder(c, $0) }) { throw blocked }

        switch purpose {
        case .personal:
            guard FileOps.isUnder(c, home) else { throw blocked }
            for excluded in [library, home.appendingPathComponent("Applications"), trash]
            where FileOps.isUnder(c, excluded) {
                throw blocked
            }
            let rel = Array(FileOps.components(c.path).dropFirst(FileOps.components(home.path).count))
            if let first = rel.first, first.hasPrefix(".") { throw blocked }
            if rel.contains(where: { $0.lowercased().hasSuffix(".photoslibrary") }) { throw blocked }

        case .appData:
            let ok = Self.appDataAreas.contains { area in
                let base = library.appendingPathComponent(area)
                return FileOps.isUnder(c, base) && !FileOps.same(c, base)
            }
            guard ok else { throw blocked }

        case .appBundle:
            let parent = c.deletingLastPathComponent()
            guard applicationsDirs.contains(where: { FileOps.same(parent, $0) }),
                  c.lastPathComponent.lowercased().hasSuffix(".app")
            else { throw blocked }

        case .trashContents:
            guard FileOps.same(c.deletingLastPathComponent(), trash) else { throw blocked }

        case .packageCache:
            let parent = c.deletingLastPathComponent()
            let ok = Self.packageCacheDirs.contains { rel in
                FileOps.same(parent, home.appendingPathComponent(rel))
            }
            guard ok else { throw blocked }
        }
    }
}
