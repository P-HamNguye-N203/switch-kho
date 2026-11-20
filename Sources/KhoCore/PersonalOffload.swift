import Foundation

public struct PersonalOffloadResult: Sendable {
    public let opID: Int64?
    /// Items left alone, with the reason.
    public let skipped: [(url: URL, reason: String)]
}

/// Offloads personal files and folders into `SwitchKho/Archive`, mirroring their path.
public enum PersonalOffload {
    public static func requests(for urls: [URL], layout: KhoLayout, leaveSymlink: Bool) -> [OffloadRequest] {
        urls.compactMap { url in
            guard let rel = layout.relativePath(layout.archiveURL(forOriginal: url)) else { return nil }
            return OffloadRequest(original: url, khoRelPath: rel, purpose: .personal, leaveSymlink: leaveSymlink)
        }
    }

    public static func offload(
        _ urls: [URL], title: String, leaveSymlink: Bool, service: OffloadService, layout: KhoLayout,
        now: @escaping @Sendable () -> Date = { Date() },
        progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> PersonalOffloadResult {
        var skipped: [(URL, String)] = []
        var chosen: [OffloadRequest] = []
        for r in requests(for: urls, layout: layout, leaveSymlink: leaveSymlink) {
            if let why = InUseCheck.reason(r.original, now: now()) {
                skipped.append((r.original, why))
                continue
            }
            do {
                try service.precheck([r])
                chosen.append(r)
            } catch {
                skipped.append((r.original, error.localizedDescription))
            }
        }
        guard !chosen.isEmpty else { return PersonalOffloadResult(opID: nil, skipped: skipped) }
        let originals = chosen.map(\.original)
        // Checked again after copying, right before the originals move.
        let opID = try service.offload(
            kind: .personal, title: title, bundleID: nil, requests: chosen,
            preHoldCheck: {
                for url in originals where InUseCheck.reason(url, now: now()) != nil {
                    throw KhoError.sourceChanged(url.lastPathComponent)
                }
            },
            progress: progress, isCancelled: isCancelled)
        return PersonalOffloadResult(opID: opID, skipped: skipped)
    }

    /// Undo while held, pull back once committed. Refuses when something new sits at an
    /// original place instead of quietly putting the item beside it.
    public static func bringBack(opID: Int64, service: OffloadService, ledger: Ledger,
                                 progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
                                 isCancelled: @escaping @Sendable () -> Bool = { false }) throws {
        guard let op = try ledger.operation(opID), op.kind == .personal else {
            throw KhoError.notFound("Thao tác #\(opID)")
        }
        // Only before anything moved back; a resumed undo or restore finds its own items there.
        let occupied = op.state == .holding || op.state == .committed
            ? service.occupiedOriginals(try ledger.items(opID)) : []
        if !occupied.isEmpty {
            throw KhoError.destinationOccupied(occupied.joined(separator: "\n")
                + "\nĐã có dữ liệu mới ở chỗ cũ — hãy đổi tên hoặc dời nó đi rồi thử lại.")
        }
        switch op.state {
        case .holding, .undoing: try service.undo(opID: opID, isCancelled: isCancelled)
        case .committed, .restoring: try service.restore(opID: opID, progress: progress, isCancelled: isCancelled)
        default: throw KhoError.invalidState("Thao tác không ở vùng chờ hay trên Kho")
        }
    }
}
