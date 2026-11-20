import Darwin
import Foundation

/// Low-level file helpers shared by every component that deletes or inspects trees.
public enum FileOps {
    /// User-settable flags that make an item refuse rename/unlink.
    public static let lockFlags = UInt32(UF_IMMUTABLE | UF_APPEND)

    /// `st_flags` of the item itself (symlinks are not followed); 0 when it does not exist.
    public static func flags(_ url: URL) -> UInt32 {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return 0 }
        return st.st_flags
    }

    /// True when the item exists (symlinks count, even dangling ones).
    public static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    public static func isSymlink(_ url: URL) -> Bool {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return false }
        return (st.st_mode & S_IFMT) == S_IFLNK
    }

    public static func inode(_ url: URL) -> UInt64? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        return UInt64(st.st_ino)
    }

    /// Clears the lock flags on one item without following symlinks.
    public static func unlock(_ url: URL) {
        let current = flags(url)
        if current & lockFlags != 0 {
            _ = lchflags(url.path, current & ~lockFlags)
        }
    }

    /// Deletes a file, symlink or directory tree. Lock flags are cleared first on every
    /// entry (top-down, never following symlinks) so Finder-locked items cannot leave
    /// undeletable debris. A missing item is not an error.
    public static func removeTree(_ url: URL) throws {
        guard exists(url) else { return }
        unlock(url)
        if !isSymlink(url), let walker = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in true })
        {
            for case let child as URL in walker {
                unlock(child)
            }
        }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            throw KhoError.io("Không xoá được \(url.path): \(error.localizedDescription)")
        }
    }

    /// `realpath(3)` of an existing path, or nil.
    public static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `realpath(3)` when the item exists, otherwise the URL unchanged. Never uses
    /// `resolvingSymlinksInPath()`, which strips the `/private` prefix.
    public static func resolved(_ url: URL) -> URL {
        guard let r = realpath(url.path) else { return url }
        return URL(fileURLWithPath: r)
    }

    /// Path components without the leading "/".
    public static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst(path.hasPrefix("/") ? 1 : 0)
            .map(String.init)
    }

    /// Component-wise, case-insensitive "is `url` equal to or inside `ancestor`".
    public static func isUnder(_ url: URL, _ ancestor: URL) -> Bool {
        let a = components(url.path).filter { !$0.isEmpty }
        let b = components(ancestor.path).filter { !$0.isEmpty }
        guard a.count >= b.count else { return false }
        for (x, y) in zip(a, b) where x.caseInsensitiveCompare(y) != .orderedSame {
            return false
        }
        return true
    }

    /// Component-wise, case-insensitive equality.
    public static func same(_ a: URL, _ b: URL) -> Bool {
        isUnder(a, b) && isUnder(b, a)
    }
}
