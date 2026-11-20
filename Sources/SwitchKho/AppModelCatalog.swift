import AppKit
import KhoCore

extension AppModel {
    // MARK: Catalog

    /// Indexes the mounted Kho when it was never indexed or the index is over a day old.
    func indexKhoIfStale(force: Bool = false) {
        guard let kho, let volume = khoVolume else { return }
        if !force, let v = try? catalog.indexedVolume(uuid: kho.uuid),
           Date().timeIntervalSince(v.lastIndexed) < 86_400 { return }
        let store = catalog, root = kho.layout.khoRoot, uuid = kho.uuid, name = volume.name
        Task {
            await jobQueue.enqueue(title: "Lập chỉ mục Kho", cancellable: true) { [weak self] ctx in
                let start = Date()
                let items = try CatalogIndexer.scan(khoRoot: root, progress: { n in ctx.report(fraction: 0, detail: "\(n) mục") },
                                                    isCancelled: { ctx.isCancelled })
                    // App data running from the Kho changes constantly and is not something to search.
                    .filter { !$0.relPath.hasPrefix("SwitchKho/Live/") && $0.relPath != "SwitchKho/Live" }
                ctx.report(fraction: 0.9, detail: "Ghi \(items.count) mục")
                try store.replaceCatalog(volumeUUID: uuid, volumeName: name, items: items, isCancelled: { ctx.isCancelled })
                let seconds = Int(Date().timeIntervalSince(start))
                await self?.catalogIndexed(count: items.count, seconds: seconds)
            }
        }
    }

    func catalogIndexed(count: Int, seconds: Int) {
        ledger.log(action: "Lập chỉ mục Kho", path: nil, detail: "\(count) mục trong \(seconds) giây", ok: true)
        catalogGeneration += 1
    }

    func catalogSearch(_ text: String) -> [CatalogEntry] {
        (try? catalog.search(text, limit: 500)) ?? []
    }

    /// The archive operation that owns a catalog entry, if it is a personal item we can bring back.
    func operation(for entry: CatalogEntry) -> LedgerOperation? {
        guard entry.item.relPath.hasPrefix("SwitchKho/Archive/") else { return nil }
        var rel = entry.item.relPath
        while rel.hasPrefix("SwitchKho/Archive/") {
            if let (op, _) = (try? ledger.item(khoRelPath: rel)) ?? nil,
               op.kind == .personal, op.state == .holding || op.state == .committed { return op }
            rel = (rel as NSString).deletingLastPathComponent
        }
        return nil
    }

    func url(for entry: CatalogEntry) -> URL? {
        guard let kho, kho.uuid == entry.volumeUUID else { return nil }
        return kho.layout.khoRoot.appendingPathComponent(entry.item.relPath)
    }

    // MARK: Personal archive

    func offloadPersonal(_ urls: [URL], leaveSymlink: Bool = false) {
        guard let kho else { lastError = "Hãy cắm Kho trước khi cất."; return }
        let service = offloadService, layout = kho.layout
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) mục"
        Task {
            do {
                let result = try await jobQueue.run(title: "Cất \(title) vào Kho", cancellable: true) { ctx in
                    try PersonalOffload.offload(urls, title: title, leaveSymlink: leaveSymlink, service: service, layout: layout,
                                                progress: { p in
                                                    ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                                                               detail: p.currentName)
                                                },
                                                isCancelled: { ctx.isCancelled })
                }
                if let opID = result.opID {
                    notify("Đã cất \(title) (#\(opID)). Bản gốc nằm trong vùng chờ \(holdDays) ngày.")
                }
                if !result.skipped.isEmpty {
                    lastError = "Bỏ qua \(result.skipped.count) mục:\n"
                        + result.skipped.prefix(5).map { "\($0.url.lastPathComponent): \($0.reason)" }.joined(separator: "\n")
                }
            } catch is CancellationError {
                notify("Đã huỷ cất \(title)")
            } catch {
                lastError = "Cất \(title): \(error.localizedDescription)"
            }
            backupLedgerIfSafe()
            refreshOperations()
            scheduleStaleFiles()
        }
    }

    func bringBackPersonal(_ op: LedgerOperation) {
        let ledger = self.ledger
        runOperation("Lấy về \(op.title ?? "#\(op.id)")", opID: op.id, done: "Đã lấy về \(op.title ?? "#\(op.id)")") { s, ctx in
            try PersonalOffload.bringBack(opID: op.id, service: s, ledger: ledger, progress: { p in
                ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0, detail: p.currentName)
            }, isCancelled: { ctx.isCancelled })
        }
    }


    // MARK: Rules

    var rules: [OffloadRule] { (try? OffloadRule.all(ledger)) ?? [] }

    func saveRule(_ rule: OffloadRule) {
        do { try rule.save(ledger) } catch { lastError = "Không lưu được quy tắc: \(error.localizedDescription)" }
        catalogGeneration += 1
    }

    func deleteRule(_ rule: OffloadRule) {
        try? rule.delete(ledger)
        catalogGeneration += 1
    }

    func ruleCandidates(_ rule: OffloadRule) async -> [RuleCandidate] {
        let ledger = self.ledger, policy = self.policy
        return await Task.detached { RuleEngine.candidates(for: rule, ledger: ledger, policy: policy) }.value
    }

    /// Automatic rules copy to the Kho, so they only run while it is mounted; Eject suspends
    /// the queue, and the job can be cancelled safely while copying.
    func enqueueAutoRules() {
        let rules = self.rules.filter { $0.enabled && $0.mode == .auto }
        guard !rules.isEmpty, let kho else { return }
        let service = offloadService, ledger = self.ledger, policy = self.policy, layout = kho.layout
        Task {
            await jobQueue.enqueue(title: "Chạy quy tắc tự động", cancellable: true) { [weak self] ctx in
                let out = RuleEngine.runAuto(rules: rules, khoMounted: true, service: service, ledger: ledger,
                                             policy: policy, layout: layout, isCancelled: { ctx.isCancelled })
                let failed = out.compactMap { r -> String? in
                    if case .failure(let e) = r.result { return "\(r.rule): \(e.localizedDescription)" }
                    return nil
                }
                await self?.rulesRan(count: out.count, failures: failed)
            }
        }
    }

    func rulesRan(count: Int, failures: [String]) {
        if !failures.isEmpty { lastError = "Quy tắc tự động: " + failures.joined(separator: "; ") }
        else if count > 0 { notify("Quy tắc tự động đã cất \(count) nhóm vào vùng chờ") }
        backupLedgerIfSafe()
        refreshOperations()
    }
}
