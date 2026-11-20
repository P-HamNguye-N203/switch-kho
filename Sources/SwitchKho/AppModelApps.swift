import AppKit
import KhoCore

extension AppModel {
    func showApps(select bundleID: String?) {
        appsSelection = bundleID
        section = .apps
        if appDataMap == nil { scanApps() }
        if let fp = footprint(bundleID) { checkEligibility(fp) }
    }

    func footprint(_ bundleID: String?) -> AppFootprint? {
        guard let bundleID else { return nil }
        return appDataMap?.footprints.first { $0.app.bundleID == bundleID }
    }

    /// Walks the bundle for file owners, so it runs off the main thread.
    func checkEligibility(_ fp: AppFootprint) {
        let ledger = self.ledger, others = appDataMap?.footprints.map(\.app) ?? []
        Task.detached { [weak self] in
            let running = RunningProcesses.isRunning(bundleID: fp.app.bundleID, appURL: fp.app.url)
            let e = AppArchiver.eligibility(for: fp, isRunning: running, ledger: ledger, otherApps: others)
            await self?.setEligibility(e, for: fp.app.bundleID)
        }
    }

    func setEligibility(_ e: ArchiveEligibility, for bundleID: String) { eligibility[bundleID] = e }

    func archiveApp(_ fp: AppFootprint) {
        guard let kho else { lastError = "Hãy cắm Kho trước khi cất app."; return }
        let service = offloadService, ledger = self.ledger, layout = kho.layout
        let others = appDataMap?.footprints.map(\.app) ?? []
        Task {
            do {
                let opID = try await jobQueue.run(title: "Cất \(fp.app.name) vào Kho", cancellable: true) { ctx in
                    try await AppArchiver.archive(
                        fp, service: service, ledger: ledger, layout: layout, otherApps: others,
                        isRunning: { RunningProcesses.isRunning(bundleID: $0.bundleID, appURL: $0.url) },
                        progress: { p in
                            ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                                       detail: p.currentName)
                        },
                        isCancelled: { ctx.isCancelled })
                }
                notify("Đã cất \(fp.app.name) (#\(opID)). Bản gốc nằm trong vùng chờ \(holdDays) ngày.")
                scanApps()
            } catch {
                lastError = "Cất \(fp.app.name): \(error.localizedDescription)"
            }
            backupLedgerIfSafe()
            refreshOperations()
        }
    }

    func restoreApp(_ op: LedgerOperation) {
        let service = offloadService, ledger = self.ledger
        busyOps.insert(op.id)
        Task {
            do {
                let result = try await jobQueue.run(title: "Lấy về \(op.title ?? "#\(op.id)")", cancellable: true) { ctx in
                    try await AppArchiver.restore(
                        opID: op.id, service: service, ledger: ledger,
                        progress: { p in
                            ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                                       detail: p.currentName)
                        },
                        isCancelled: { ctx.isCancelled })
                }
                if result.signatureBroken {
                    lastError = "Chữ ký của \(op.title ?? "app") sau khi lấy về không hợp lệ — đừng mở app, hãy cài lại."
                } else if !result.relocated.isEmpty {
                    lastError = "Một phần được đưa về chỗ khác vì chỗ cũ đã có dữ liệu:\n" + result.relocated.joined(separator: "\n")
                } else {
                    notify("Đã lấy về \(op.title ?? "#\(op.id)")")
                }
                scanApps()
            } catch {
                lastError = "Lấy về \(op.title ?? "#\(op.id)"): \(error.localizedDescription)"
            }
            busyOps.remove(op.id)
            backupLedgerIfSafe()
            refreshOperations()
        }
    }
}
