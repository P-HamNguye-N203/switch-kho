import Foundation

/// Moves an app's Application Support data to the Kho, leaving a locked symlink behind, so
/// the app keeps running while the Kho is plugged in.
public enum LiveRelocator {
    public static let notWithoutKho = "Ứng dụng sẽ không mở được khi Kho chưa cắm"

    public static func eligibleFolders(_ fp: AppFootprint) -> [AppDataFolder] {
        fp.folders.filter { $0.area == .applicationSupport }
    }

    public static func eligibility(for fp: AppFootprint, isRunning: Bool, ledger: Ledger) -> ArchiveEligibility {
        var e = ArchiveEligibility()
        if isRunning { e.blockers.append("Đang chạy — hãy thoát trước") }
        if fp.hasVMImage {
            e.blockers.append("Có ảnh đĩa máy ảo — rút Kho có thể hỏng dữ liệu; hãy dùng Dọn dẹp hoặc Cất cả app")
        }
        let folders = eligibleFolders(fp)
        if folders.isEmpty { e.blockers.append("Chỉ hỗ trợ dữ liệu trong Application Support") }
        for folder in folders {
            if let (op, _) = (try? ledger.activeItems(overlapping: folder.url.path))?.first {
                e.blockers.append("Dữ liệu đang thuộc thao tác #\(op.id)")
                break
            }
        }
        e.warnings.append(notWithoutKho)
        return e
    }

    /// Only Application Support folders: sandbox containers are checked by macOS and do not
    /// work through a symlink, and caches should be cleaned rather than moved.
    public static func requests(for fp: AppFootprint, folders: [AppDataFolder], home: URL,
                                layout: KhoLayout) -> [OffloadRequest] {
        let root = layout.relativePath(layout.liveRoot(bundleID: fp.app.bundleID))!
        let homeCount = FileOps.components(home.path).count
        return folders.filter { $0.area == .applicationSupport }.map { folder in
            let rel = FileOps.components(folder.url.path).dropFirst(homeCount).joined(separator: "/")
            return OffloadRequest(original: folder.url, khoRelPath: "\(root)/\(rel)",
                                  purpose: .appData, leaveSymlink: true)
        }
    }

    public static func relocate(
        _ fp: AppFootprint, folders: [AppDataFolder], service: OffloadService, ledger: Ledger,
        layout: KhoLayout, home: URL = FileManager.default.homeDirectoryForCurrentUser,
        isRunning: @escaping @Sendable (InstalledApp) -> Bool,
        progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws -> Int64 {
        let app = fp.app
        let e = eligibility(for: fp, isRunning: isRunning(app), ledger: ledger)
        guard e.allowed else { throw KhoError.invalidState(e.blockers.joined(separator: "; ")) }
        let chosen = requests(for: fp, folders: folders, home: home, layout: layout)
        guard !chosen.isEmpty else { throw KhoError.invalidState("Chưa chọn thư mục nào") }
        let check: @Sendable () throws -> Void = {
            if isRunning(app) { throw KhoError.appRunning(app.name) }
        }
        return try service.offload(kind: .appLive, title: app.name, bundleID: app.bundleID, requests: chosen,
                                   preHoldCheck: check, afterEachHold: check,
                                   progress: progress, isCancelled: isCancelled)
    }

    /// Puts the data back as real folders: the current Kho copy, never the old original.
    public static func bringBack(
        opID: Int64, service: OffloadService, ledger: Ledger,
        progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) throws {
        guard let op = try ledger.operation(opID), op.kind == .appLive else {
            throw KhoError.notFound("Thao tác #\(opID)")
        }
        // A real folder where our link should be is data made while the Kho was away; it has to
        // be kept (set aside) first or it would be lost or mixed in.
        let replaced = try ledger.items(opID).filter { item in
            item.role == .normal && !item.restored && !item.released && item.stage != .swapped
                && FileOps.exists(item.originalURL)
                && !(FileOps.isSymlink(item.originalURL) && isOurLink(item.originalURL, service))
        }
        if !replaced.isEmpty {
            throw KhoError.destinationOccupied(replaced.map(\.originalPath).joined(separator: "\n")
                + "\nĐã có thư mục thật ở chỗ liên kết — hãy bấm \"Giữ bản trên Kho\" trước.")
        }
        switch op.state {
        case .holding, .undoing: try service.undo(opID: opID, isCancelled: isCancelled)
        case .committed, .restoring: try service.restore(opID: opID, progress: progress, isCancelled: isCancelled)
        default: throw KhoError.invalidState("Thao tác không ở vùng chờ hay trên Kho")
        }
    }

    static func isOurLink(_ url: URL, _ service: OffloadService) -> Bool {
        guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) else { return false }
        return service.isOurLinkTarget(target)
    }
}
