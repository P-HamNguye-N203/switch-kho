import Darwin
import Foundation

public struct CopyProgress: Sendable {
    public let bytesDone: Int64
    public let bytesTotal: Int64
    public let currentName: String
}

/// Identity of a source file at the time it was listed, used to detect later changes.
public struct SourceStamp: Codable, Sendable, Equatable {
    public let dev: Int64
    public let ino: UInt64
    public let size: Int64
    public let mtime: Double

    static func of(_ url: URL) -> SourceStamp? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        let m = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
        return SourceStamp(dev: Int64(st.st_dev), ino: UInt64(st.st_ino), size: Int64(st.st_size), mtime: m)
    }
}

public struct CopiedFile: Codable, Sendable, Equatable {
    /// Relative to the copied root; empty when the root itself is a file.
    public let relPath: String
    public let logicalSize: Int64
    public let allocated: Int64
    public let segments: [Segment]
    public let digest: String
    public let stamp: SourceStamp
}

public struct CopyReport: Sendable {
    public let destination: URL
    public let files: [CopiedFile]
    public let allocatedBytes: Int64
}

/// Copies a tree (files, directories, symlinks) with SHA-256 verification, sparse-file
/// preservation, progress, cancellation and a source snapshot for later change detection.
public final class VerifiedCopier: Sendable {
    let capacityProvider: @Sendable (URL) throws -> Int64
    let afterFileCopied: (@Sendable (URL) -> Void)?

    public init(
        capacityProvider: @escaping @Sendable (URL) throws -> Int64 = VerifiedCopier.volumeCapacity,
        afterFileCopied: (@Sendable (URL) -> Void)? = nil
    ) {
        self.capacityProvider = capacityProvider
        self.afterFileCopied = afterFileCopied
    }

    public static func volumeCapacity(_ url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        ])
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        return Int64(values.volumeAvailableCapacity ?? 0)
    }

    enum Kind { case directory, file, symlink }

    struct Entry {
        let rel: String
        let src: URL
        let kind: Kind
        let stamp: SourceStamp?
        let allocated: Int64
    }

    /// Lists `src` parents-first without following symlinks.
    func listEntries(_ src: URL) throws -> [Entry] {
        var result: [Entry] = []
        func visit(_ url: URL, rel: String) throws {
            var st = stat()
            guard lstat(url.path, &st) == 0 else { throw KhoError.notFound(url.path) }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                result.append(Entry(rel: rel, src: url, kind: .directory, stamp: nil, allocated: 0))
                let names = try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
                for name in names {
                    try visit(url.appendingPathComponent(name), rel: rel.isEmpty ? name : rel + "/" + name)
                }
            case S_IFREG:
                result.append(Entry(rel: rel, src: url, kind: .file, stamp: SourceStamp.of(url),
                                    allocated: Int64(st.st_blocks) * 512))
            case S_IFLNK:
                result.append(Entry(rel: rel, src: url, kind: .symlink, stamp: nil, allocated: 0))
            default:
                throw KhoError.io("Không chép được file đặc biệt: \(url.path)")
            }
        }
        try visit(src, rel: "")
        return result
    }

    public func copy(
        from src: URL, to dst: URL,
        onPartialCreated: @Sendable (URL) -> Void = { _ in },
        progress: @escaping @Sendable (CopyProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> CopyReport {
        let entries = try listEntries(src)
        let bytesTotal = entries.reduce(Int64(0)) { $0 + $1.allocated }
        let parent = dst.deletingLastPathComponent()
        let available = try capacityProvider(parent)
        if bytesTotal + (1 << 30) > available {
            throw KhoError.insufficientSpace(needed: bytesTotal + (1 << 30), available: available)
        }
        if FileOps.exists(dst) { throw KhoError.destinationOccupied(dst.path) }

        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let partial = parent.appendingPathComponent(".switchkho-partial-\(UUID().uuidString)")
        onPartialCreated(partial)

        do {
            var files: [CopiedFile] = []
            var done: Int64 = 0
            for entry in entries {
                if isCancelled() { throw CancellationError() }
                let target = entry.rel.isEmpty ? partial : partial.appendingPathComponent(entry.rel)
                switch entry.kind {
                case .directory:
                    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                case .symlink:
                    try runCopyfile(entry.src, target, flags: COPYFILE_ALL | COPYFILE_NOFOLLOW, box: nil)
                case .file:
                    let base = done
                    let box = ProgressBox(isCancelled: isCancelled) { copied in
                        progress(CopyProgress(bytesDone: base + copied, bytesTotal: bytesTotal,
                                              currentName: entry.src.lastPathComponent))
                    }
                    try runCopyfile(entry.src, target,
                                    flags: COPYFILE_ALL | COPYFILE_DATA_SPARSE | COPYFILE_NOFOLLOW, box: box)
                    FileOps.unlock(target)
                    try fullSync(target)
                    afterFileCopied?(target)
                    files.append(try verify(entry, copy: target))
                    done += entry.allocated
                    progress(CopyProgress(bytesDone: done, bytesTotal: bytesTotal,
                                          currentName: entry.src.lastPathComponent))
                }
            }
            for entry in entries.reversed() where entry.kind == .directory {
                let target = entry.rel.isEmpty ? partial : partial.appendingPathComponent(entry.rel)
                try runCopyfile(entry.src, target, flags: COPYFILE_METADATA, box: nil)
                FileOps.unlock(target)
            }
            if FileOps.exists(dst) { throw KhoError.destinationOccupied(dst.path) }
            guard rename(partial.path, dst.path) == 0 else {
                throw KhoError.io("Không đổi tên được bản tạm: \(String(cString: strerror(errno)))")
            }
            let allocated = files.reduce(Int64(0)) { $0 + $1.allocated }
            return CopyReport(destination: dst, files: files, allocatedBytes: allocated)
        } catch {
            try? FileOps.removeTree(partial)
            throw error
        }
    }

    func verify(_ entry: Entry, copy target: URL) throws -> CopiedFile {
        let (segments, digest) = try ContentDigest.segmentsAndDigest(entry.src)
        let copyDigest = try ContentDigest.digest(target, segments: segments)
        let name = entry.rel.isEmpty ? entry.src.lastPathComponent : entry.rel
        guard copyDigest == digest else { throw KhoError.verifyFailed(name) }
        let srcAllocated = try SparseFile.allocatedBytes(entry.src)
        if !SparseFile.isCompressed(entry.src) {
            let dstAllocated = try SparseFile.allocatedBytes(target)
            guard dstAllocated <= srcAllocated * 105 / 100 + (1 << 20) else {
                throw KhoError.verifyFailed("\(name) (bản sao chiếm \(ByteFormat.string(dstAllocated)))")
            }
        }
        var st = stat()
        lstat(entry.src.path, &st)
        return CopiedFile(relPath: entry.rel, logicalSize: Int64(st.st_size), allocated: srcAllocated,
                          segments: segments, digest: digest,
                          stamp: entry.stamp ?? SourceStamp(dev: 0, ino: 0, size: 0, mtime: 0))
    }

    func fullSync(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw KhoError.io("Không mở được \(url.path)") }
        defer { close(fd) }
        _ = fcntl(fd, F_FULLFSYNC)
    }

    func runCopyfile(_ src: URL, _ dst: URL, flags: Int32, box: ProgressBox?) throws {
        guard let state = copyfile_state_alloc() else { throw KhoError.io("copyfile_state_alloc") }
        defer { copyfile_state_free(state) }
        if let box {
            // copyfile stores the callback and context values themselves, not pointers to them.
            let cb: copyfile_callback_t = copyfileProgressCallback
            _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CB),
                                   unsafeBitCast(cb, to: UnsafeRawPointer.self))
            let ctx = Unmanaged.passUnretained(box).toOpaque()
            _ = copyfile_state_set(state, UInt32(COPYFILE_STATE_STATUS_CTX), UnsafeRawPointer(ctx))
        }
        let rc = withExtendedLifetime(box) {
            copyfile(src.path, dst.path, state, copyfile_flags_t(flags))
        }
        if rc != 0 {
            if box?.cancelled == true { throw CancellationError() }
            throw KhoError.io("Chép lỗi \(src.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    /// Returns the `relPath` of the first file whose stamp differs from the recorded one
    /// (or that disappeared), or nil when every file is unchanged.
    public static func changedSource(_ files: [CopiedFile], under src: URL) -> String? {
        for f in files {
            let url = f.relPath.isEmpty ? src : src.appendingPathComponent(f.relPath)
            if SourceStamp.of(url) != f.stamp {
                return f.relPath.isEmpty ? src.lastPathComponent : f.relPath
            }
        }
        return nil
    }
}

/// Context handed to the C progress callback. Only touched on the copying thread.
final class ProgressBox {
    let isCancelled: @Sendable () -> Bool
    let onBytes: (Int64) -> Void
    var cancelled = false

    init(isCancelled: @escaping @Sendable () -> Bool, onBytes: @escaping (Int64) -> Void) {
        self.isCancelled = isCancelled
        self.onBytes = onBytes
    }
}

private func copyfileProgressCallback(
    what: Int32, stage: Int32, state: copyfile_state_t?,
    src: UnsafePointer<CChar>?, dst: UnsafePointer<CChar>?, ctx: UnsafeMutableRawPointer?
) -> Int32 {
    guard let ctx else { return COPYFILE_CONTINUE }
    let box = Unmanaged<ProgressBox>.fromOpaque(ctx).takeUnretainedValue()
    if what == COPYFILE_COPY_DATA && stage == COPYFILE_PROGRESS, let state {
        var copied: off_t = 0
        copyfile_state_get(state, UInt32(COPYFILE_STATE_COPIED), &copied)
        box.onBytes(Int64(copied))
    }
    if box.isCancelled() {
        box.cancelled = true
        return COPYFILE_QUIT
    }
    return COPYFILE_CONTINUE
}
