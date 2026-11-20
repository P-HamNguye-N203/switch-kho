import Foundation

/// A folder (or a large file) in a scanned tree. Small files are summarised per folder.
public struct ScanNode: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let isDirectory: Bool
    public let size: Int64
    public let fileCount: Int
    public let children: [ScanNode]
    public let smallFilesSize: Int64
    public let smallFilesCount: Int
    public let modified: Date?

    public var name: String { url.lastPathComponent }
}

public struct FileEntry: Sendable, Identifiable, Hashable {
    public var id: String { url.path }
    public let url: URL
    public let size: Int64
    public let modified: Date?
}

public struct ScanResult: Sendable {
    public let root: ScanNode
    public let largestFiles: [FileEntry]
    public let totalFiles: Int
    public let unreadable: Int
}

/// Recursive size scanner using allocated sizes. Symlinks are not followed, folders on
/// another device (mount points such as NFS shares inside home) are skipped, hard links are
/// counted once, and Switch Kho's own data folder is ignored.
public struct DirectoryScanner: Sendable {
    public var individualFileThreshold: Int64 = 1 << 20
    public var largestFilesLimit = 300
    public var largestFileMinimum: Int64 = 10 << 20
    /// Extra folders to skip (tests use it to simulate another device).
    public var skip: (@Sendable (URL) -> Bool)?
    public var ignored: [URL]

    static let skipPaths: Set<String> = ["/Volumes", "/System/Volumes", "/dev", "/private/var/vm", "/cores"]
    static let keys: [URLResourceKey] = [
        .isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey, .contentModificationDateKey, .volumeIdentifierKey,
        .linkCountKey, .fileResourceIdentifierKey,
    ]

    public init(ignored: [URL] = [FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/SwitchKho")], skip: (@Sendable (URL) -> Bool)? = nil) {
        self.ignored = ignored
        self.skip = skip
    }

    public func scan(_ root: URL, progress: (@Sendable (Int) -> Void)? = nil,
                     isCancelled: @Sendable () -> Bool = { false }) throws -> ScanResult {
        let rootValues = try root.resourceValues(forKeys: Set(Self.keys))
        let rootVolume = rootValues.volumeIdentifier as? NSObject
        var largest: [FileEntry] = []
        var total = 0
        var unreadable = 0
        var seenLinks = Set<NSObject>()

        func visit(_ dir: URL, modified: Date?) throws -> ScanNode {
            if isCancelled() { throw CancellationError() }
            var size: Int64 = 0, count = 0, smallSize: Int64 = 0, smallCount = 0
            var children: [ScanNode] = []
            guard let contents = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: Self.keys, options: [])
            else {
                unreadable += 1
                return ScanNode(url: dir, isDirectory: true, size: 0, fileCount: 0, children: [],
                                smallFilesSize: 0, smallFilesCount: 0, modified: modified)
            }
            for url in contents {
                guard let v = try? url.resourceValues(forKeys: Set(Self.keys)) else {
                    unreadable += 1
                    continue
                }
                if v.isSymbolicLink == true { continue }
                if v.isDirectory == true {
                    if Self.skipPaths.contains(url.path) || skip?(url) == true { continue }
                    if ignored.contains(where: { FileOps.same($0, url) }) { continue }
                    if let vol = v.volumeIdentifier as? NSObject, let rootVolume, !vol.isEqual(rootVolume) { continue }
                    let child = try visit(url, modified: v.contentModificationDate)
                    children.append(child)
                    size += child.size
                    count += child.fileCount
                } else {
                    if (v.linkCount ?? 1) > 1, let rid = v.fileResourceIdentifier as? NSObject {
                        if seenLinks.contains(rid) { continue }
                        seenLinks.insert(rid)
                    }
                    let fileSize = Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
                    size += fileSize
                    count += 1
                    total += 1
                    if total % 2000 == 0 { progress?(total) }
                    if fileSize >= individualFileThreshold {
                        children.append(ScanNode(url: url, isDirectory: false, size: fileSize, fileCount: 1,
                                                 children: [], smallFilesSize: 0, smallFilesCount: 0,
                                                 modified: v.contentModificationDate))
                    } else {
                        smallSize += fileSize
                        smallCount += 1
                    }
                    if fileSize >= largestFileMinimum {
                        largest.append(FileEntry(url: url, size: fileSize, modified: v.contentModificationDate))
                    }
                }
            }
            return ScanNode(url: dir, isDirectory: true, size: size, fileCount: count,
                            children: children.sorted { $0.size > $1.size },
                            smallFilesSize: smallSize, smallFilesCount: smallCount, modified: modified)
        }

        let node = try visit(root, modified: rootValues.contentModificationDate)
        progress?(total)
        largest.sort { $0.size > $1.size }
        return ScanResult(root: node, largestFiles: Array(largest.prefix(largestFilesLimit)),
                          totalFiles: total, unreadable: unreadable)
    }

    /// Allocated size of a single item (file or whole folder tree), hard links counted once.
    public static func size(of url: URL) -> Int64 {
        AppDataMapper.stats(url).allocated
    }

    /// Files not used for at least `days`, oldest first. Only files of at least `minSize` are
    /// checked so the usage lookups stay fast.
    public static func staleFiles(in result: ScanResult, days: Int, minSize: Int64,
                                  now: Date = Date()) -> [FileEntry] {
        var out: [(FileEntry, Date)] = []
        func walk(_ node: ScanNode) {
            for child in node.children {
                if child.isDirectory {
                    walk(child)
                    continue
                }
                guard child.size >= minSize, let used = FileUsage.effective(child.url)?.date else { continue }
                if now.timeIntervalSince(used) >= Double(days) * 86_400 {
                    out.append((FileEntry(url: child.url, size: child.size, modified: used), used))
                }
            }
        }
        walk(result.root)
        return out.sorted { $0.1 < $1.1 }.map(\.0)
    }
}
