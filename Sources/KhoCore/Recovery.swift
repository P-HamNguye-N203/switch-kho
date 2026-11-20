import Foundation

public struct RecoveryReport: Sendable, Equatable {
    public var orphanHoldingDirs: [String] = []
    public var needsReview: [Int64] = []
    public var errors: [String] = []
}

extension OffloadService {
    /// Brings every unfinished operation back to a consistent state after a crash, using the
    /// same helpers as the normal paths. Runs at launch and every time a Kho is mounted.
    /// Never deletes orphaned holding folders; it only reports them.
    public func recover() -> RecoveryReport {
        var report = RecoveryReport()
        let ops = (try? ledger.operations()) ?? []

        for op in ops where !OperationState.finished.contains(op.state) {
            if op.needsReview {
                report.needsReview.append(op.id)
                continue
            }
            do {
                switch op.state {
                case .copying:
                    failCopying(op, error: "Bị gián đoạn")
                case .moving:
                    rollbackMoving(op, error: "Bị gián đoạn")
                case .holding where op.holdingUntil == nil:
                    try ledger.setHoldingUntil(op.id, now().addingTimeInterval(Double(holdDays()) * 86_400))
                case .committing:
                    try holding.purge(opUID: op.uid)
                    try ledger.transition(op.id, from: [.committing], to: .committed)
                case .undoing:
                    do {
                        try undo(opID: op.id)
                    } catch KhoError.khoOffline, KhoError.appRunning {
                        // Retried next time.
                    }
                case .restoring:
                    try ledger.transition(op.id, from: [.restoring], to: .committed,
                                          error: "Lấy về bị gián đoạn, hãy thử lại")
                default:
                    break
                }
            } catch {
                report.errors.append("#\(op.id): \(error.localizedDescription)")
            }
        }

        cleanPartials()
        if let kho = mountedKho() {
            cleanKhoTemporaries(kho.layout.base)
            drainPendingCleanup()
        }

        let live: Set<OperationState> = [.moving, .holding, .committing, .undoing]
        let liveUIDs = Set(((try? ledger.operations(states: live)) ?? []).map(\.uid))
        report.orphanHoldingDirs = holding.slotDirectories().filter { !liveUIDs.contains($0) }
        return report
    }

    func cleanPartials() {
        let referenced = Set(((try? ledger.operations()) ?? []).flatMap { op in
            ((try? ledger.items(op.id)) ?? []).compactMap(\.stagePath)
        })
        for path in (try? ledger.partials()) ?? [] {
            let url = URL(fileURLWithPath: path)
            if referenced.contains(path) { continue }
            if url.lastPathComponent.hasPrefix(".switchkho-partial-") {
                do {
                    try FileOps.removeTree(url)
                } catch {
                    ledger.log(action: "Không dọn được bản tạm", path: path,
                               detail: error.localizedDescription, ok: false)
                    continue
                }
            }
            try? ledger.removePartial(path)
        }
    }

    func cleanKhoTemporaries(_ base: URL, depth: Int = 0) {
        guard depth < 12,
              let names = try? FileManager.default.contentsOfDirectory(atPath: base.path)
        else { return }
        for name in names {
            let url = base.appendingPathComponent(name)
            if name.hasPrefix(".switchkho-partial-") || name.hasPrefix(".ledger-backup.tmp-") {
                try? FileOps.removeTree(url)
                try? ledger.removePartial(url.path)
                continue
            }
            var isDir: ObjCBool = false
            if !FileOps.isSymlink(url), FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir),
               isDir.boolValue
            {
                cleanKhoTemporaries(url, depth: depth + 1)
            }
        }
    }
}
