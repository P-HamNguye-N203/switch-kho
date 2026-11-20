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

    func runCleanup(_ c: CleanupCandidate) {
        let ledger = self.ledger, policy = self.policy
        Task {
            do {
                let outcome = try await jobQueue.run(title: "Dọn: \(c.title)") { _ in
                    try await CleanupExecutor.execute(
                        c, policy: policy, ledger: ledger,
                        isRunning: { url in
                            let id = Bundle(url: url)?.bundleIdentifier ?? ""
                            return RunningProcesses.isRunning(bundleID: id, appURL: url)
                        })
                }
                var message = "Đã giải phóng \(ByteFormat.string(outcome.freedBytes)) (\(c.title))"
                if c.id == "docker-prune" { message += ". Docker.raw sẽ co lại sau vài phút" }
                if !outcome.failed.isEmpty {
                    lastError = "\(c.title): \(outcome.failed.count) mục không xoá được, ví dụ \(outcome.failed[0].0.lastPathComponent): \(outcome.failed[0].1)"
                }
                notify(message)
                cleanupCandidates.removeAll { $0.id == c.id }
            } catch {
                lastError = "Dọn \(c.title): \(error.localizedDescription)"
            }
        }
    }
}
