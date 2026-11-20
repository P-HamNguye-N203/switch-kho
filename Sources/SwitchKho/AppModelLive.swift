import AppKit
import KhoCore

extension AppModel {
    func showLive(select bundleID: String?) {
        liveSelection = bundleID
        section = .live
        if appDataMap == nil { scanApps() }
    }

    /// Runs `body` as a cancellable job with progress, then refreshes everything the guard watches.
    private func liveJob(_ title: String, opID: Int64? = nil, done: String,
                         _ body: @escaping @Sendable (@escaping @Sendable (CopyProgress) -> Void,
                                                      @escaping @Sendable () -> Bool) throws -> Void) {
        if let opID { busyOps.insert(opID) }
        Task {
            do {
                try await jobQueue.run(title: title, cancellable: true) { ctx in
                    try body({ p in
                        ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                                   detail: p.currentName)
                    }, { ctx.isCancelled })
                }
                notify(done)
            } catch {
                lastError = "\(title): \(error.localizedDescription)"
            }
            if let opID { busyOps.remove(opID) }
            backupLedgerIfSafe()
            refreshOperations()
            liveGuard?.reloadLiveApps()
            checkLiveIntegrity()
        }
    }

    func relocateLive(_ fp: AppFootprint, folders: [AppDataFolder]) {
        guard let kho else { lastError = "Hãy cắm Kho trước."; return }
        let service = offloadService, ledger = self.ledger, layout = kho.layout
        liveJob("Chạy \(fp.app.name) từ Kho", done: "\(fp.app.name) giờ chạy từ Kho. Luôn tháo Kho bằng nút Eject của Switch Kho.") { progress, cancelled in
            _ = try LiveRelocator.relocate(fp, folders: folders, service: service, ledger: ledger, layout: layout,
                                           isRunning: { RunningProcesses.isRunning(bundleID: $0.bundleID, appURL: $0.url) },
                                           progress: progress, isCancelled: cancelled)
        }
        // The guard only works while Switch Kho runs.
        if !LoginItem.isEnabled {
            do { try LoginItem.setEnabled(true) } catch { lastError = "Không bật được mục đăng nhập: \(error.localizedDescription)" }
        }
    }

    func bringBackLive(_ op: LedgerOperation) {
        let service = offloadService, ledger = self.ledger
        liveJob("Đưa \(op.title ?? "#\(op.id)") về máy", opID: op.id, done: "Đã đưa \(op.title ?? "#\(op.id)") về máy") { progress, cancelled in
            try LiveRelocator.bringBack(opID: op.id, service: service, ledger: ledger, progress: progress, isCancelled: cancelled)
        }
    }

    /// Keeps a folder the app made while the Kho was away: copied to the Kho, then held.
    func keepCopyMadeWhileAway(_ op: LedgerOperation, folder: URL) {
        let service = offloadService
        liveJob("Giữ bản tạo khi Kho vắng", opID: op.id, done: "Đã giữ bản tạo khi Kho vắng và nối lại liên kết") { progress, cancelled in
            _ = try service.setAside(liveOpID: op.id, folder: folder, progress: progress, isCancelled: cancelled)
        }
    }

    func relinkLive(_ op: LedgerOperation, original: URL) {
        let service = offloadService, ledger = self.ledger
        liveJob("Tạo lại liên kết", opID: op.id, done: "Đã tạo lại liên kết") { _, _ in
            guard let item = try ledger.items(op.id).first(where: { $0.originalPath == original.path }) else {
                throw KhoError.notFound(original.path)
            }
            try service.relink(opID: op.id, itemID: item.id)
        }
    }

    func liveEligibility(_ fp: AppFootprint) -> ArchiveEligibility {
        LiveRelocator.eligibility(for: fp, isRunning: runningBundles.contains(fp.app.bundleID), ledger: ledger)
    }
}
