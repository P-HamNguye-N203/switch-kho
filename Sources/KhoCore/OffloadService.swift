import Darwin
import Foundation
import Synchronization

public struct OffloadRequest: Sendable {
    public let original: URL
    public let khoRelPath: String
    public let purpose: PathPurpose
    public let leaveSymlink: Bool

    public init(original: URL, khoRelPath: String, purpose: PathPurpose, leaveSymlink: Bool) {
        self.original = original
        self.khoRelPath = khoRelPath
        self.purpose = purpose
        self.leaveSymlink = leaveSymlink
    }
}

/// A Kho volume that has been confirmed (identity checked) and is mounted right now.
public struct MountedKho: Sendable, Equatable {
    public let uuid: String
    public let layout: KhoLayout

    public init(uuid: String, layout: KhoLayout) {
        self.uuid = uuid
        self.layout = layout
    }
}

/// Holds a value set from a non-escaping `@Sendable` callback.
final class PathBox: Sendable {
    let value = Mutex<String?>(nil)
}

/// Coordinates offload, commit, undo, restore and set-aside. Every state change is written
/// to the ledger before any file is touched, and every Kho path is derived from the Kho
/// that is mounted at the moment it is used.
public final class OffloadService: Sendable {
    public let ledger: Ledger
    public let holding: HoldingArea
    public let policy: PathPolicy
    public let copier: VerifiedCopier
    /// The fixed Kho link (`<data>/KhoLink`) every symlink of ours points through.
    public let linkRoot: URL
    let mountedKho: @Sendable () -> MountedKho?
    let holdDays: @Sendable () -> Int
    let now: @Sendable () -> Date
    let appRunning: @Sendable (_ bundleID: String) -> Bool
    let onKhoChanged: (@Sendable (_ added: [String], _ removed: [String]) -> Void)?

    public init(
        ledger: Ledger, holding: HoldingArea, policy: PathPolicy, copier: VerifiedCopier,
        linkRoot: URL,
        mountedKho: @escaping @Sendable () -> MountedKho?,
        holdDays: @escaping @Sendable () -> Int,
        now: @escaping @Sendable () -> Date,
        appRunning: @escaping @Sendable (_ bundleID: String) -> Bool = { _ in false },
        onKhoChanged: (@Sendable (_ added: [String], _ removed: [String]) -> Void)? = nil
    ) {
        self.ledger = ledger
        self.holding = holding
        self.policy = policy
        self.copier = copier
        self.linkRoot = linkRoot
        self.mountedKho = mountedKho
        self.holdDays = holdDays
        self.now = now
        self.appRunning = appRunning
        self.onKhoChanged = onKhoChanged
    }

    // MARK: Helpers

    func khoFor(_ op: Operation) -> KhoLayout? {
        guard let kho = mountedKho(), kho.uuid == op.khoUUID else { return nil }
        return kho.layout
    }

    func deleteOnKho(_ op: Operation, relPath: String?) throws {
        guard let relPath else { return }
        if let layout = khoFor(op) {
            do {
                try FileOps.removeTree(layout.absoluteURL(relative: relPath))
            } catch {
                // Retried whenever this Kho is mounted again.
                try? ledger.addPendingCleanup(khoUUID: op.khoUUID, khoRelPath: relPath)
                throw error
            }
        } else {
            try ledger.addPendingCleanup(khoUUID: op.khoUUID, khoRelPath: relPath)
        }
    }

    /// The only place in KhoCore that creates a symlink.
    func makeOurSymlink(at url: URL, relPath: String, layout: KhoLayout) throws {
        let target = try layout.symlinkTarget(relative: relPath)
        do {
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        } catch {
            throw KhoError.io("Không tạo được liên kết tại \(url.path): \(error.localizedDescription)")
        }
        _ = lchflags(url.path, UInt32(UF_IMMUTABLE))
    }

    /// True when `target` was written by this app. Every link it creates points through the
    /// fixed Kho link, so this holds whether or not a Kho is mounted.
    func isOurLinkTarget(_ target: String) -> Bool {
        let url = URL(fileURLWithPath: target)
        return FileOps.isUnder(url, linkRoot) && !FileOps.same(url, linkRoot)
    }

    /// Removes `url` only when it is a symlink created by this app.
    func removeOurSymlink(at url: URL) throws {
        guard FileOps.isSymlink(url),
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path),
              isOurLinkTarget(target)
        else { return }
        _ = lchflags(url.path, 0)
        guard unlink(url.path) == 0 else {
            throw KhoError.io("Không gỡ được liên kết \(url.path): \(String(cString: strerror(errno)))")
        }
    }

    func revalidate(_ item: OperationItem, op: Operation) throws {
        try policy.check(item.originalURL, purpose: item.purpose)
        guard let held = item.holdingPath else { return }
        let parts = FileOps.components(held)
        let rootParts = FileOps.components(holding.root.path)
        let rest = Array(parts.dropFirst(rootParts.count))
        guard parts.count == rootParts.count + 2,
              FileOps.isUnder(URL(fileURLWithPath: held), holding.root),
              rest[0] == op.uid, rest[1].hasSuffix(".held"), rest[1].hasPrefix("\(item.idx)-"),
              !rest.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw KhoError.blocked(held) }
    }

    func verifyOnKho(_ op: Operation, progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
                     isCancelled: @escaping @Sendable () -> Bool = { false }) -> String? {
        guard let layout = khoFor(op) else { return KhoError.khoOffline.localizedDescription }
        guard let items = try? ledger.items(op.id) else { return "Không đọc được sổ cái" }
        for item in items {
            guard let rel = item.khoRelPath else { return "Mục #\(item.id) không có bản trên Kho" }
            if isCancelled() { return "Đã huỷ kiểm tra" }
            guard let root = try? layout.absoluteURL(relative: rel) else { return "Đường dẫn không hợp lệ: \(rel)" }
            if !FileOps.exists(root) { return "Không thấy trên Kho: \(rel)" }
            if op.kind == .appLive && item.role == .normal { continue }
            guard let files = item.decodedFiles() else { return "Sổ cái thiếu danh sách file của \(rel)" }
            let total = files.reduce(Int64(0)) { $0 + $1.logicalSize }
            var done: Int64 = 0
            for f in files {
                if isCancelled() { return "Đã huỷ kiểm tra" }
                let url = f.relPath.isEmpty ? root : root.appendingPathComponent(f.relPath)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { return "Thiếu trên Kho: \(rel)/\(f.relPath)" }
                guard Int64(st.st_size) == f.logicalSize else { return "Kích thước khác: \(rel)/\(f.relPath)" }
                guard let d = try? ContentDigest.digest(url, segments: f.segments), d == f.digest else {
                    return "Nội dung khác: \(rel)/\(f.relPath)"
                }
                done += f.logicalSize
                progress(CopyProgress(bytesDone: done, bytesTotal: total, currentName: url.lastPathComponent))
            }
        }
        return nil
    }

    func failCopying(_ op: Operation, error: String) {
        let items = (try? ledger.items(op.id)) ?? []
        defer {
            // Folders the copy created and that are now empty (deepest first).
            if let layout = khoFor(op) {
                let urls = items.compactMap(\.khoRelPath).compactMap { try? layout.absoluteURL(relative: $0) }
                for url in urls.sorted(by: { $0.pathComponents.count > $1.pathComponents.count }) {
                    removeEmptyParents(of: url, layout: layout)
                }
            }
        }
        for item in items {
            do {
                try deleteOnKho(op, relPath: item.khoRelPath)
            } catch {
                ledger.log(action: "Không xoá được bản trên Kho, sẽ thử lại", path: item.khoRelPath,
                           detail: error.localizedDescription, ok: false)
            }
        }
        _ = try? ledger.transition(op.id, from: [.copying, .moving], to: .failed, error: error)
        ledger.log(action: "Cất thất bại", path: op.title, detail: error, ok: false)
    }

    /// Puts every held original back. Only when all of them are back is the Kho copy
    /// removed and the operation marked failed; otherwise it stays `moving` for Recovery.
    func rollbackMoving(_ op: Operation, error: String) {
        var allBack = true
        for item in (try? ledger.items(op.id)) ?? [] {
            guard let held = item.holdingPath, FileOps.exists(URL(fileURLWithPath: held)) else { continue }
            do {
                try removeOurSymlink(at: item.originalURL)
                try holding.release(URL(fileURLWithPath: held), to: item.originalURL, expectedIno: item.origIno)
            } catch {
                allBack = false
                ledger.log(action: "Chưa trả được bản gốc", path: item.originalPath,
                           detail: error.localizedDescription, ok: false)
            }
        }
        guard allBack else {
            try? ledger.setError(op.id, error)
            return
        }
        failCopying(op, error: error)
    }

    func uniqueSibling(_ url: URL, suffix: String?) -> URL {
        guard FileOps.exists(url) else { return url }
        if let suffix {
            return HoldingArea.siblingCandidates(url, suffix: suffix).first { !FileOps.exists($0) } ?? url
        }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let stem = ext.isEmpty ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        for n in 2...999 {
            let name = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let c = dir.appendingPathComponent(name)
            if !FileOps.exists(c) { return c }
        }
        return url
    }

    func requireOperation(_ id: Int64) throws -> Operation {
        guard let op = try ledger.operation(id) else { throw KhoError.notFound("Thao tác #\(id)") }
        return op
    }

    func checkAppNotRunning(_ op: Operation) throws {
        guard op.kind == .appCold || op.kind == .appLive, let bundle = op.bundleID else { return }
        if appRunning(bundle) { throw KhoError.appRunning(op.title ?? bundle) }
    }

    func copyTracked(from src: URL, to dst: URL, progress: @escaping @Sendable (CopyProgress) -> Void,
                     isCancelled: @escaping @Sendable () -> Bool) throws -> CopyReport {
        let box = PathBox()
        let ledger = self.ledger
        // A partial copy on the Kho is also recorded by Kho identity, so it is found again even
        // if the Kho is unplugged mid-copy or mounts at another path later.
        let kho = mountedKho()
        let khoRel: @Sendable (URL) -> String? = { p in kho.flatMap { $0.layout.relativePath(p) } }
        defer {
            if let path = box.value.withLock({ $0 }) {
                let p = URL(fileURLWithPath: path)
                // Gone with its parent still there: really removed. Parent missing: the volume
                // went away, keep the records for the next mount.
                if !FileOps.exists(p) && FileOps.exists(p.deletingLastPathComponent()) {
                    try? ledger.removePartial(path)
                    if let kho, let rel = khoRel(p) { try? ledger.removePendingCleanup(khoUUID: kho.uuid, khoRelPath: rel) }
                }
            }
        }
        return try copier.copy(from: src, to: dst, onPartialCreated: { p in
            box.value.withLock { $0 = p.path }
            try ledger.addPartial(p.path)
            if let kho, let rel = khoRel(p) { try ledger.addPendingCleanup(khoUUID: kho.uuid, khoRelPath: rel) }
        }, progress: progress, isCancelled: isCancelled)
    }

    /// Copies `src` into `folder` (between this Mac and the Kho, either way) without touching
    /// the source. The side on this Mac must pass the personal-file policy; the copy is
    /// verified and its partial is tracked like an offload's.
    @discardableResult
    public func copyOnly(_ src: URL, intoFolder folder: URL,
                         progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
                         isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> URL {
        let kho = mountedKho()
        let onKho: (URL) -> Bool = { url in kho?.layout.relativePath(url) != nil || kho.map { FileOps.same(url, $0.layout.khoRoot) } == true }
        let dst = folder.appendingPathComponent(src.lastPathComponent)
        if FileOps.isSymlink(src) { throw KhoError.blocked(src.path) }
        if !onKho(src) { try policy.check(src, purpose: .personal) }
        if !onKho(dst) { try policy.check(dst, purpose: .personal) }
        if onKho(dst), let kho, FileOps.isUnder(dst, kho.layout.live) || FileOps.isUnder(dst, kho.layout.apps) {
            throw KhoError.blocked(dst.path)
        }
        do {
            _ = try copyTracked(from: src, to: dst, progress: progress, isCancelled: isCancelled)
            ledger.log(action: "copy", path: src.path, detail: dst.path, ok: true)
        } catch {
            ledger.log(action: "copy", path: src.path, detail: "\(dst.path): \(error.localizedDescription)", ok: false)
            throw error
        }
        if onKho(dst), let rel = kho?.layout.relativePath(dst) { onKhoChanged?([rel], []) }
        return dst
    }

    static func encodeFiles(_ files: [CopiedFile]) -> String {
        (try? String(data: JSONEncoder().encode(files), encoding: .utf8)) ?? "[]"
    }

    // MARK: Offload

    struct PlannedItem {
        let request: OffloadRequest
        let role: ItemRole
    }

    func precheck(_ requests: [OffloadRequest], ignoringOp: Int64? = nil) throws {
        for r in requests {
            try policy.check(r.original, purpose: r.purpose)
            if FileOps.isSymlink(r.original) { throw KhoError.blocked(r.original.path) }
            guard FileOps.exists(r.original) else { throw KhoError.notFound(r.original.path) }
            let overlapping = try ledger.activeItems(overlapping: r.original.path)
                .filter { $0.0.id != ignoringOp }
            if let first = overlapping.first { throw KhoError.alreadyManaged("#\(first.0.id)") }
            let locks = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)
            if FileOps.flags(r.original) & locks != 0 {
                throw KhoError.notDeletable("Mục đang bị khoá (Locked)")
            }
            let parent = r.original.deletingLastPathComponent()
            if FileOps.flags(parent) & locks != 0
                || !FileManager.default.isDeletableFile(atPath: r.original.path)
                || !FileManager.default.isWritableFile(atPath: parent.path)
            {
                throw KhoError.notDeletable(r.original.path)
            }
        }
    }

    public func offload(
        kind: OperationKind, title: String, bundleID: String?, requests: [OffloadRequest],
        preHoldCheck: @escaping @Sendable () throws -> Void = {},
        afterEachHold: (@Sendable () throws -> Void)? = nil,
        progress: @escaping @Sendable (CopyProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Int64 {
        guard mountedKho() != nil else { throw KhoError.khoOffline }
        try precheck(requests)
        // Re-checked after every move: throwing puts every original back.
        let afterHold: ((OperationItem, KhoLayout) throws -> Void)? = afterEachHold.map { check in { _, _ in try check() } }
        return try runOffload(kind: kind, title: title, bundleID: bundleID,
                              planned: requests.map { PlannedItem(request: $0, role: .normal) },
                              preHoldCheck: preHoldCheck, afterHold: afterHold,
                              progress: progress, isCancelled: isCancelled)
    }

    func runOffload(
        kind: OperationKind, title: String, bundleID: String?, planned: [PlannedItem],
        preHoldCheck: @escaping @Sendable () throws -> Void,
        afterHold: ((OperationItem, KhoLayout) throws -> Void)?,
        progress: @escaping @Sendable (CopyProgress) -> Void,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Int64 {
        guard let kho = mountedKho() else { throw KhoError.khoOffline }
        let opID = try ledger.createOperation(kind: kind, title: title, bundleID: bundleID, khoUUID: kho.uuid)
        var itemIDs: [Int64] = []
        for (idx, p) in planned.enumerated() {
            itemIDs.append(try ledger.addItem(
                opID: opID, idx: idx, originalPath: p.request.original.path, purpose: p.request.purpose,
                role: p.role, origIno: FileOps.inode(p.request.original), leftSymlink: p.request.leaveSymlink))
        }
        var op = try requireOperation(opID)

        // Copy and verify, then make sure nothing changed before the originals move.
        do {
            for (i, p) in planned.enumerated() {
                let dst = uniqueSibling(try kho.layout.absoluteURL(relative: p.request.khoRelPath), suffix: nil)
                guard let rel = kho.layout.relativePath(dst) else { throw KhoError.blocked(dst.path) }
                // The Kho may have been unplugged after an earlier item; never copy into whatever
                // now sits at its mount path.
                guard FileOps.exists(kho.layout.identityFile) else { throw KhoError.khoOffline }
                // Record the destination before copying: a crash right after the copier's final
                // rename must still leave the Kho copy findable for cleanup.
                try ledger.updateItem(itemIDs[i], khoRelPath: .some(rel))
                let report: CopyReport
                do {
                    report = try copyTracked(from: p.request.original, to: dst, progress: progress,
                                             isCancelled: isCancelled)
                } catch KhoError.destinationOccupied(let path) {
                    // Whatever sits there now is not ours; never delete it.
                    try ledger.updateItem(itemIDs[i], khoRelPath: .some(nil))
                    throw KhoError.destinationOccupied(path)
                }
                guard FileOps.same(report.destination, dst) else { throw KhoError.blocked(report.destination.path) }
                try ledger.updateItem(itemIDs[i], allocated: report.allocatedBytes,
                                      filesJSON: Self.encodeFiles(report.files))
            }
            try preHoldCheck()
            for item in try ledger.items(opID) {
                if let changed = VerifiedCopier.changedSource(item.files(), under: item.originalURL) {
                    throw KhoError.sourceChanged(changed)
                }
            }
        } catch {
            failCopying(op, error: error.localizedDescription)
            throw error
        }

        guard try ledger.transition(opID, from: [.copying], to: .moving) else {
            throw KhoError.invalidState("Thao tác #\(opID) không còn ở bước chép")
        }
        op = try requireOperation(opID)
        do {
            for item in try ledger.items(opID) {
                let slot = holding.slotURL(opUID: op.uid, index: item.idx, original: item.originalURL)
                try ledger.updateItem(item.id, holdingPath: .some(slot.path))
                try holding.hold(item.originalURL, to: slot)
                if item.leftSymlink, let rel = item.khoRelPath {
                    try makeOurSymlink(at: item.originalURL, relPath: rel, layout: kho.layout)
                    try ledger.updateItem(item.id, symlinkCreated: true)
                }
                if let afterHold, let fresh = try ledger.item(id: item.id) {
                    try afterHold(fresh, kho.layout)
                }
            }
        } catch {
            rollbackMoving(op, error: error.localizedDescription)
            throw error
        }

        let until = now().addingTimeInterval(Double(holdDays()) * 86_400)
        guard try ledger.transition(opID, from: [.moving], to: .holding, holdingUntil: until) else {
            throw KhoError.invalidState("Thao tác #\(opID) không còn ở bước dời")
        }
        ledger.log(action: "Đã cất", path: title, detail: "#\(opID)", ok: true)
        onKhoChanged?(try ledger.items(opID).compactMap(\.khoRelPath), [])
        return opID
    }

    // MARK: Commit

    func commitOne(_ op: Operation, progress: @escaping @Sendable (CopyProgress) -> Void,
                   isCancelled: @escaping @Sendable () -> Bool) throws -> Bool {
        if let problem = verifyOnKho(op, progress: progress, isCancelled: isCancelled) {
            if isCancelled() { throw CancellationError() }
            try? ledger.setError(op.id, problem)
            ledger.log(action: "Chưa xoá vùng chờ vì bản trên Kho không khớp", path: op.title,
                       detail: problem, ok: false)
            throw KhoError.verifyFailed(problem)
        }
        guard try ledger.transition(op.id, from: [.holding], to: .committing) else { return false }
        try holding.purge(opUID: op.uid)
        try ledger.transition(op.id, from: [.committing], to: .committed)
        try? ledger.setError(op.id, nil)
        ledger.log(action: "Đã xoá vùng chờ", path: op.title, detail: "#\(op.id)", ok: true)
        return true
    }

    /// Commits every due holding operation whose Kho is mounted and verifies. Never throws.
    @discardableResult
    public func commitDue(progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
                          isCancelled: @escaping @Sendable () -> Bool = { false }) -> [Int64] {
        let due = ((try? ledger.operations(states: [.holding])) ?? [])
            .filter { !$0.needsReview && ($0.holdingUntil ?? .distantFuture) <= now() }
            .sorted { ($0.holdingUntil ?? .distantFuture) < ($1.holdingUntil ?? .distantFuture) }
        var committed: [Int64] = []
        for op in due {
            if isCancelled() { break }
            guard khoFor(op) != nil else { continue }
            do {
                if try commitOne(op, progress: progress, isCancelled: isCancelled) { committed.append(op.id) }
            } catch is CancellationError {
                break
            } catch {
                try? ledger.setError(op.id, error.localizedDescription)
            }
        }
        return committed
    }

    public func commitNow(opID: Int64, progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
                          isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        let op = try requireOperation(opID)
        guard op.state == .holding else { throw KhoError.invalidState("Thao tác không ở vùng chờ") }
        guard !op.needsReview else { throw KhoError.invalidState("Thao tác cần được xem lại trước") }
        guard khoFor(op) != nil else { throw KhoError.khoOffline }
        guard try commitOne(op, progress: progress, isCancelled: isCancelled) else {
            throw KhoError.invalidState("Thao tác #\(opID) đã đổi trạng thái")
        }
    }

    public func drainPendingCleanup() {
        guard let kho = mountedKho() else { return }
        let ops = (try? ledger.operations()) ?? []
        func owners(_ states: Set<OperationState>) -> [String] {
            ops.filter { states.contains($0.state) && $0.khoUUID == kho.uuid }
                .flatMap { (try? ledger.items($0.id)) ?? [] }.compactMap(\.khoRelPath)
        }
        // The Kho copy is the data itself for these: a stale cleanup row must never touch it.
        let owned = owners([.holding, .committed])
        // These are still changing; decide once they settle.
        let busy = owners([.copying, .moving, .undoing, .restoring, .committing])
        func overlaps(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
        for row in (try? ledger.pendingCleanup(khoUUID: kho.uuid)) ?? [] {
            if busy.contains(where: { overlaps($0, row.khoRelPath) }) { continue }
            if owned.contains(where: { overlaps($0, row.khoRelPath) }) {
                try? ledger.removePendingCleanup(row.id)
                ledger.log(action: "Bỏ mục dọn trùng dữ liệu đang dùng", path: row.khoRelPath, detail: nil, ok: true)
                continue
            }
            do {
                try FileOps.removeTree(kho.layout.absoluteURL(relative: row.khoRelPath))
                try? ledger.removePendingCleanup(row.id)
                ledger.log(action: "Đã dọn bản trên Kho", path: row.khoRelPath, detail: nil, ok: true)
            } catch KhoError.blocked {
                // A path the layout refuses can never be cleaned; drop it instead of retrying forever.
                try? ledger.removePendingCleanup(row.id)
                ledger.log(action: "Bỏ mục dọn không hợp lệ", path: row.khoRelPath, detail: nil, ok: false)
            } catch {
                ledger.log(action: "Không dọn được bản trên Kho, sẽ thử lại", path: row.khoRelPath,
                           detail: error.localizedDescription, ok: false)
            }
        }
    }

    // MARK: Pull back

    /// Files and symlinks below `root` with their size and modification time, without
    /// following symlinks. Copies made with `COPYFILE_ALL` keep mtimes, so a staged copy and
    /// its Kho source have equal signatures until either side is written to.
    static func treeSignature(_ root: URL) -> [String: String]? {
        var out: [String: String] = [:]
        var st = stat()
        guard lstat(root.path, &st) == 0 else { return nil }
        func add(_ rel: String, _ st: stat) {
            let kind = st.st_mode & S_IFMT
            guard kind == S_IFREG || kind == S_IFLNK else { return }
            out[rel] = "\(kind)/\(st.st_size)/\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
        if (st.st_mode & S_IFMT) != S_IFDIR {
            add("", st)
            return out
        }
        guard let walker = FileManager.default.enumerator(atPath: root.path) else { return nil }
        for case let rel as String in walker {
            var cst = stat()
            if lstat(root.appendingPathComponent(rel).path, &cst) == 0 { add(rel, cst) }
        }
        return out
    }

    func pullBackFromKho(_ itemID: Int64, op: Operation, layout: KhoLayout, target: URL,
                         progress: @escaping @Sendable (CopyProgress) -> Void,
                         isCancelled: @escaping @Sendable () -> Bool, retried: Bool = false) throws {
        guard var item = try ledger.item(id: itemID), let rel = item.khoRelPath else {
            throw KhoError.invalidState("Mục không có bản trên Kho")
        }
        let src = try layout.absoluteURL(relative: rel)

        // A staged copy from an earlier attempt is only reused when the Kho copy has not
        // changed since (an app may have written to it in between); otherwise copy again.
        if item.stage == .copied, let stagePath = item.stagePath {
            let stage = URL(fileURLWithPath: stagePath)
            if FileOps.exists(stage), Self.treeSignature(stage) != Self.treeSignature(src) {
                try FileOps.removeTree(stage)
                try? ledger.removePartial(stagePath)
            }
            if !FileOps.exists(stage) {
                // Swapped already (crash right after the rename) only when the restored path
                // is a real item that matches the Kho copy, never our own symlink.
                if let done = item.restoredPath.map(URL.init(fileURLWithPath:)), !FileOps.isSymlink(done),
                   FileOps.exists(done), Self.treeSignature(done) == Self.treeSignature(src)
                {
                    try ledger.updateItem(itemID, stage: .some(.swapped))
                    try? ledger.removePartial(stagePath)
                    return
                }
                try ledger.updateItem(itemID, stage: .some(nil), stagePath: .some(nil))
                try? ledger.removePartial(stagePath)
                guard !retried else { throw KhoError.invalidState("Bản tạm bị mất hai lần liên tiếp") }
                return try pullBackFromKho(itemID, op: op, layout: layout, target: target, progress: progress,
                                           isCancelled: isCancelled, retried: true)
            }
        }

        if item.stage == nil {
            let stage = uniqueSibling(
                target.deletingLastPathComponent().appendingPathComponent(".switchkho-partial-\(UUID().uuidString)"),
                suffix: nil)
            try ledger.addPartial(stage.path)
            do {
                let report = try copyTracked(from: src, to: stage, progress: progress, isCancelled: isCancelled)
                if let changed = VerifiedCopier.changedSource(report.files, under: src) {
                    throw KhoError.sourceChanged(changed)
                }
            } catch {
                try? FileOps.removeTree(stage)
                try? ledger.removePartial(stage.path)
                throw error
            }
            try ledger.updateItem(itemID, stage: .some(.copied), stagePath: .some(stage.path),
                                  restoredPath: .some(target.path))
            item = try ledger.item(id: itemID) ?? item
        }

        if item.stage == .copied, let stagePath = item.stagePath {
            let stage = URL(fileURLWithPath: stagePath)
            try checkAppNotRunning(op)
            try removeOurSymlink(at: target)
            var dest = target
            if FileOps.exists(dest) {
                dest = uniqueSibling(target, suffix: "khôi phục")
                try ledger.updateItem(itemID, restoredPath: .some(dest.path))
            }
            guard renamex_np(stage.path, dest.path, UInt32(RENAME_EXCL)) == 0 else {
                throw KhoError.io("Không đặt được bản về \(dest.path): \(String(cString: strerror(errno)))")
            }
            try ledger.updateItem(itemID, stage: .some(.swapped))
            try? ledger.removePartial(stagePath)
        }
    }

    // MARK: Accept the Kho copy

    /// The user confirms that the current Kho copy is correct (for example after editing
    /// files through a symlink). Re-snapshots every file on the Kho so later checks compare
    /// against what is there now. Only the user triggers this; nothing calls it automatically.
    public func acceptKhoCopy(opID: Int64, isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        let op = try requireOperation(opID)
        guard op.state == .holding || op.state == .committed else {
            throw KhoError.invalidState("Chỉ chấp nhận được khi thao tác đang ở vùng chờ hoặc đã cất xong")
        }
        guard let layout = khoFor(op) else { throw KhoError.khoOffline }
        var updates: [(Int64, String)] = []
        for item in try ledger.items(opID) {
            guard let rel = item.khoRelPath else { throw KhoError.invalidState("Mục #\(item.id) không có bản trên Kho") }
            let root = try layout.absoluteURL(relative: rel)
            guard FileOps.exists(root) else { throw KhoError.notFound(root.path) }
            var files: [CopiedFile] = []
            for entry in try copier.listEntries(root) where entry.kind == .file {
                if isCancelled() { throw CancellationError() }
                let (segments, digest) = try ContentDigest.segmentsAndDigest(entry.src)
                guard let stamp = entry.stamp else { continue }
                files.append(CopiedFile(relPath: entry.rel, logicalSize: stamp.size, allocated: entry.allocated,
                                        segments: segments, digest: digest, stamp: stamp))
            }
            updates.append((item.id, Self.encodeFiles(files)))
        }
        for (id, json) in updates { try ledger.updateItem(id, filesJSON: json) }
        try ledger.setError(opID, nil)
        ledger.log(action: "Đã chấp nhận bản hiện tại trên Kho", path: op.title, detail: "#\(opID)", ok: true)
    }

    // MARK: Undo

    public func undo(opID: Int64, isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        let op = try requireOperation(opID)
        guard op.state == .holding || op.state == .undoing else {
            throw KhoError.invalidState("Chỉ hoàn tác được thao tác đang ở vùng chờ")
        }
        let items = try ledger.items(opID)
        if items.contains(where: \.symlinkCreated), khoFor(op) == nil { throw KhoError.khoOffline }
        try checkAppNotRunning(op)
        guard try ledger.transition(opID, from: [.holding, .undoing], to: .undoing) else {
            throw KhoError.invalidState("Thao tác #\(opID) đã đổi trạng thái")
        }

        do {
            for item in items where !item.released {
                if isCancelled() { throw CancellationError() }
                try revalidate(item, op: op)
                let held = item.holdingPath.map(URL.init(fileURLWithPath:))
                if item.role == .setAside, let held {
                    try holding.release(held, to: item.originalURL, expectedIno: item.origIno,
                                        suffix: "bản khi Kho vắng")
                } else if item.symlinkCreated {
                    guard let layout = khoFor(op) else { throw KhoError.khoOffline }
                    try pullBackFromKho(item.id, op: op, layout: layout, target: item.originalURL,
                                        progress: { _ in }, isCancelled: isCancelled)
                    if let held { try FileOps.removeTree(held) }
                } else if let held {
                    try removeOurSymlink(at: item.originalURL)
                    let back = try holding.release(held, to: item.originalURL, expectedIno: item.origIno)
                    if !FileOps.same(back, item.originalURL) { try ledger.updateItem(item.id, restoredPath: .some(back.path)) }
                }
                try ledger.updateItem(item.id, released: true)
            }
        } catch {
            try? ledger.setError(opID, error.localizedDescription)
            let retryLater = error is CancellationError
                || error as? KhoError == .khoOffline
                || { if case KhoError.appRunning = error { return true } else { return false } }()
            if retryLater { throw error }
            let fresh = (try? ledger.items(opID)) ?? []
            if !fresh.contains(where: { $0.released || $0.stage == .swapped }) {
                for item in fresh {
                    if let s = item.stagePath {
                        try? FileOps.removeTree(URL(fileURLWithPath: s))
                        try? ledger.removePartial(s)
                    }
                    try? ledger.updateItem(item.id, stage: .some(nil), stagePath: .some(nil))
                }
                _ = try? ledger.transition(opID, from: [.undoing], to: .holding, error: error.localizedDescription)
            }
            throw error
        }

        var removed: [String] = []
        for item in try ledger.items(opID) {
            do {
                try deleteOnKho(op, relPath: item.khoRelPath)
                if let rel = item.khoRelPath { removed.append(rel) }
            } catch {
                ledger.log(action: "Không xoá được bản trên Kho, sẽ thử lại", path: item.khoRelPath,
                           detail: error.localizedDescription, ok: false)
            }
        }
        try ledger.transition(opID, from: [.undoing], to: .undone)
        try? ledger.setError(opID, nil)
        try? holding.purge(opUID: op.uid)
        ledger.log(action: "Đã hoàn tác", path: op.title, detail: "#\(opID)", ok: true)
        onKhoChanged?([], removed)
    }

    // MARK: Restore

    public func restore(opID: Int64, progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
                        isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        var op = try requireOperation(opID)
        if op.state == .holding {
            try undo(opID: opID, isCancelled: isCancelled)
            return
        }
        guard op.state == .committed || op.state == .restoring else {
            throw KhoError.invalidState("Chỉ lấy về được thao tác đã cất xong")
        }
        guard !op.needsReview else { throw KhoError.invalidState("Thao tác cần được xem lại trước") }
        guard let layout = khoFor(op) else { throw KhoError.khoOffline }
        try checkAppNotRunning(op)
        if op.kind != .appLive, verifyOnKho(op, isCancelled: isCancelled) != nil {
            if isCancelled() { throw CancellationError() }
            throw KhoError.verifyFailed("Bản trên Kho đã thay đổi so với lúc cất")
        }
        guard try ledger.transition(opID, from: [.committed, .restoring], to: .restoring) else {
            throw KhoError.invalidState("Thao tác #\(opID) đã đổi trạng thái")
        }
        op = try requireOperation(opID)

        do {
            for item in try ledger.items(opID) where !item.restored {
                if isCancelled() { throw CancellationError() }
                try revalidate(item, op: op)
                var target = item.originalURL
                if item.role == .setAside {
                    // The original place is the live link; this copy goes beside it, like undo.
                    if let done = item.restoredPath { target = URL(fileURLWithPath: done) } else {
                        target = HoldingArea.siblingCandidates(item.originalURL, suffix: "bản khi Kho vắng")
                            .first { !FileOps.exists($0) } ?? target
                        try ledger.updateItem(item.id, restoredPath: .some(target.path))
                    }
                }
                try pullBackFromKho(item.id, op: op, layout: layout, target: target,
                                    progress: progress, isCancelled: isCancelled)
                try ledger.updateItem(item.id, restored: true)
            }
        } catch {
            _ = try? ledger.transition(opID, from: [.restoring], to: .committed, error: error.localizedDescription)
            throw error
        }

        var removed: [String] = []
        for item in try ledger.items(opID) {
            guard let rel = item.khoRelPath else { continue }
            do {
                try deleteOnKho(op, relPath: rel)
                removed.append(rel)
                if let mounted = khoFor(op) { removeEmptyParents(of: try mounted.absoluteURL(relative: rel), layout: mounted) }
            } catch {
                ledger.log(action: "Không xoá được bản trên Kho, sẽ thử lại", path: rel,
                           detail: error.localizedDescription, ok: false)
            }
        }
        try ledger.transition(opID, from: [.restoring], to: .restored)
        try? ledger.setError(opID, nil)
        ledger.log(action: "Đã lấy về", path: op.title, detail: "#\(opID)", ok: true)
        onKhoChanged?([], removed)
    }

    func removeEmptyParents(of url: URL, layout: KhoLayout) {
        let stops = [layout.archive, layout.apps, layout.live]
        var dir = url.deletingLastPathComponent()
        while stops.contains(where: { FileOps.isUnder(dir, $0) && !FileOps.same(dir, $0) }) {
            guard rmdir(dir.path) == 0 else { break }
            dir = dir.deletingLastPathComponent()
        }
    }

    // MARK: Set aside

    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    /// Original places of items not yet back where something other than our own link sits now
    /// (a reinstalled app, a new folder made meanwhile).
    public func occupiedOriginals(_ items: [OperationItem]) -> [String] {
        items.filter { item in
            guard item.role == .normal, !item.restored, !item.released, item.stage != .swapped,
                  FileOps.exists(item.originalURL) else { return false }
            if FileOps.isSymlink(item.originalURL),
               let target = try? FileManager.default.destinationOfSymbolicLink(atPath: item.originalPath),
               isOurLinkTarget(target) { return false }
            return true
        }.map(\.originalPath)
    }

    /// Recreates a missing link of a live operation. The only other place links are made is
    /// the offload itself.
    public func relink(opID: Int64, itemID: Int64) throws {
        let op = try requireOperation(opID)
        guard op.kind == .appLive, op.state == .holding || op.state == .committed else {
            throw KhoError.invalidState("Chỉ tạo lại liên kết cho app đang chạy từ Kho")
        }
        guard let layout = khoFor(op) else { throw KhoError.khoOffline }
        try checkAppNotRunning(op)
        guard let item = try ledger.items(opID).first(where: { $0.id == itemID }), item.role == .normal,
              !item.restored, let rel = item.khoRelPath
        else { throw KhoError.notFound("Mục #\(itemID)") }
        guard !FileOps.exists(item.originalURL) else { throw KhoError.destinationOccupied(item.originalPath) }
        guard FileOps.exists(try layout.absoluteURL(relative: rel)) else {
            throw KhoError.notFound("Dữ liệu trên Kho: \(rel)")
        }
        try makeOurSymlink(at: item.originalURL, relPath: rel, layout: layout)
        try ledger.updateItem(itemID, symlinkCreated: true)
        ledger.log(action: "Tạo lại liên kết", path: item.originalPath, detail: nil, ok: true)
    }

    /// Keeps a folder an app created while the Kho was away: copies it to the Kho first,
    /// then moves it into holding and puts the live operation's symlink back.
    public func setAside(liveOpID: Int64, folder original: URL,
                         progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
                         isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> Int64 {
        let live = try requireOperation(liveOpID)
        guard live.kind == .appLive, live.state == .holding || live.state == .committed,
              let bundle = live.bundleID,
              let liveItem = try ledger.items(liveOpID).first(where: { FileOps.same($0.originalURL, original) }),
              let liveRel = liveItem.khoRelPath
        else { throw KhoError.invalidState("Không phải thư mục của một app đang chạy từ Kho") }
        guard khoFor(live) != nil else { throw KhoError.khoOffline }
        var isDir: ObjCBool = false
        guard !FileOps.isSymlink(original),
              FileManager.default.fileExists(atPath: original.path, isDirectory: &isDir), isDir.boolValue
        else { throw KhoError.invalidState("Chỗ này không phải thư mục thật") }

        let rel = "SwitchKho/Live/\(bundle)/_khi-kho-vang-\(Self.stamp(now()))/\(original.lastPathComponent)"
        let request = OffloadRequest(original: original, khoRelPath: rel, purpose: liveItem.purpose,
                                     leaveSymlink: false)
        try precheck([request], ignoringOp: liveOpID)
        return try runOffload(
            kind: .appLive, title: "Bản tạo khi Kho vắng: \(original.lastPathComponent)", bundleID: bundle,
            planned: [PlannedItem(request: request, role: .setAside)],
            preHoldCheck: {}, afterHold: { [self] item, layout in
                try makeOurSymlink(at: item.originalURL, relPath: liveRel, layout: layout)
            }, progress: progress, isCancelled: isCancelled)
    }
}
