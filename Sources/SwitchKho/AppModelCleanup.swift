import AppKit
import KhoCore

extension AppModel {
    static let scanCleanupTitle = "Tìm rác có thể dọn"

    var isScanningCleanup: Bool { hasActiveJob { $0 == Self.scanCleanupTitle } }

    var visibleCleanupCandidates: [CleanupCandidate] {
        guard let filter = cleanupFilter else { return cleanupCandidates }
        return cleanupCandidates.filter { $0.id.hasSuffix(":\(filter)") }
    }

    /// Opens the cleanup screen narrowed to one app.
    func showCleanup(for bundleID: String?) {
        cleanupFilter = bundleID
        section = .cleanup
        if cleanupCandidates.isEmpty { scanCleanup() }
    }

    /// Discovers candidates; scans apps first when the analyzer has not run yet.
    func scanCleanup() {
        let ledger = self.ledger, existing = appDataMap
        Task {
            await jobQueue.enqueue(title: Self.scanCleanupTitle, cancellable: true) { [weak self] ctx in
                let home = FileManager.default.homeDirectoryForCurrentUser
                var map = existing
                if map == nil {
                    ctx.report(fraction: 0.1, detail: "Đo dữ liệu ứng dụng")
                    let apps = AppCatalog.scan()
                    let raw = (try? ledger.settings(withPrefix: "appdata.override.")) ?? [:]
                    let overrides = Dictionary(raw.map { (String($0.key.dropFirst("appdata.override.".count)), $0.value) },
                                               uniquingKeysWith: { a, _ in a })
                    let m = AppDataMapper.map(home: home, apps: apps, overrides: overrides)
                    map = m
                    let running = Self.runningBundleIDs(m.footprints.map(\.app))
                    await self?.setAppDataMap(m, running: running)
                }
                if ctx.isCancelled { throw CancellationError() }
                ctx.report(fraction: 0.5, detail: "Tìm các nhóm rác")
                let found = CleanupCatalog.discover(home: home, appDataMap: map!)
                await self?.setCleanupCandidates(found)
            }
        }
    }

    func setCleanupCandidates(_ c: [CleanupCandidate]) { cleanupCandidates = c }

    func requirementText(_ r: AppStateRequirement) -> String? {
        switch r {
        case .none: return nil
        case .mustBeQuit(let app): return "Cần thoát \(app.deletingPathExtension().lastPathComponent)"
        case .mustBeRunning(let app): return "Cần mở \(app.deletingPathExtension().lastPathComponent)"
        case .commandSucceeds(_, _, let hint): return hint
        }
    }

    func previewCleanup(_ c: CleanupCandidate) {
        guard case .command(let exe, _, let previewArgs?) = c.method else { return }
        Task {
            var text = ""
            do {
                text = try await CommandRunner.run(exe, previewArgs, timeout: 60).output
                if c.id == "docker-prune" {
                    text += "\n" + (try await CommandRunner.run(exe, ["system", "df", "-v"], timeout: 60).output)
                }
            } catch {
                text = error.localizedDescription
            }
            cleanupPreviews[c.id] = text.isEmpty ? "(không có gì)" : text
        }
    }

    /// Runs every chosen group as one job and reports a single summary; groups that failed,
    /// fully or partly, stay in the list.
    func runCleanup(_ items: [CleanupCandidate]) {
        let items = items.filter { !cleanupRunning.contains($0.id) }
        guard !items.isEmpty else { return }
        let ledger = self.ledger, policy = self.policy
        cleanupRunning.formUnion(items.map(\.id))
        let title = items.count == 1 ? "Dọn: \(items[0].title)" : "Dọn \(items.count) nhóm"
        Task {
            let results: [(CleanupCandidate, Result<CleanupOutcome, any Error>)] = (try? await jobQueue.run(title: title) { ctx in
                var out: [(CleanupCandidate, Result<CleanupOutcome, any Error>)] = []
                for (i, c) in items.enumerated() {
                    if ctx.isCancelled { break }
                    ctx.report(fraction: Double(i) / Double(items.count), detail: c.title)
                    do {
                        out.append((c, .success(try await CleanupExecutor.execute(
                            c, policy: policy, ledger: ledger,
                            isRunning: { url in
                                let id = Bundle(url: url)?.bundleIdentifier ?? ""
                                return RunningProcesses.isRunning(bundleID: id, appURL: url)
                            }))))
                    } catch {
                        out.append((c, .failure(error)))
                    }
                }
                return out
            }) ?? []
            var freed: Int64 = 0
            var problems: [String] = []
            var docker = false
            for (c, result) in results {
                switch result {
                case .success(let o):
                    freed += o.freedBytes
                    if c.id == "docker-prune" { docker = true }
                    if o.failed.isEmpty {
                        cleanupCandidates.removeAll { $0.id == c.id }
                    } else {
                        problems.append("\(c.title): \(o.failed.count) mục không xoá được (ví dụ \(o.failed[0].0.lastPathComponent): \(o.failed[0].1))")
                    }
                case .failure(let e):
                    problems.append("\(c.title): \(e.localizedDescription)")
                }
            }
            cleanupRunning.subtract(items.map(\.id))
            if results.contains(where: { if case .success = $0.1 { true } else { false } }) {
                notify("Đã giải phóng \(ByteFormat.string(freed))" + (docker ? ". Docker.raw sẽ co lại sau vài phút" : ""))
            }
            if !problems.isEmpty {
                lastError = problems.count == 1 ? problems[0]
                    : "\(problems.count) nhóm gặp lỗi:\n" + problems.joined(separator: "\n")
            }
            if results.count < items.count && problems.isEmpty { lastError = "Đã dừng giữa chừng" }
        }
    }
}
