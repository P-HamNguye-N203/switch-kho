import AppKit
import KhoCore
import Observation
import Synchronization
import SwiftUI

/// The Kho that is confirmed and mounted right now, read by background services.
final class KhoCell: Sendable {
    let value = Mutex<MountedKho?>(nil)
}

/// Latest app catalog, read by the running-app check.
final class AppIndexCell: Sendable {
    let value = Mutex<[String: URL]>([:])
}

/// One row of the holding list.
struct HoldingRow: Identifiable, Hashable {
    var id: Int64 { op.id }
    let op: LedgerOperation
    let items: [OperationItem]
    let bytes: Int64
    let overdue: Bool
}

@MainActor @Observable
final class AppModel {
    static let holdingWarnBytes: Int64 = 20_000_000_000
    static let lowSpaceBytes: Int64 = 15_000_000_000

    let dataDir: URL
    let ledger: Ledger
    let jobQueue = JobQueue()
    let holding: HoldingArea
    let policy = PathPolicy.live()
    let copier = VerifiedCopier()
    let offloadService: OffloadService
    /// Searchable index of the Kho, in its own database next to the ledger.
    let catalog: CatalogStore
    let linkRoot: URL
    let khoCell = KhoCell()
    private let appIndex = AppIndexCell()
    private let lock: InstanceLock

    var section: SidebarSection? = .overview
    var volumes: [VolumeInfo] = []
    var kho: MountedKho?
    var khoProblem: String?
    var jobs: [JobSnapshot] = []
    var appDataMap: AppDataMap?
    var recoveryReport: RecoveryReport?
    var offerLedgerRestore = false
    var holdingRows: [HoldingRow] = []
    /// Personal archives still in holding or on the Kho.
    var personalArchives: [LedgerOperation] = []
    var holdingBytes: Int64 = 0
    var lastError: String?
    /// Short success message shown at the bottom of the window, cleared after a few seconds.
    var notice: String?
    /// Last thing the guard did (an app stopped because the Kho went away).
    var guardNotice: String?
    var liveGuard: LiveGuard?
    /// Link status of every guarded live operation, by operation ID.
    var liveIssues: [Int64: [LiveStatus]] = [:]
    var liveSelection: String?
    var isEjecting = false
    /// Bumped whenever the catalog or the rules change, so views reload.
    var catalogGeneration = 0
    /// Only the normal data folder registers the real app as a login item; test sessions don't.
    var usesDefaultDataDir: Bool {
        FileOps.same(dataDir, FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SwitchKho"))
    }
    var folderScan: ScanResult?
    var folderPath: [ScanNode] = []
    var staleDays = 180 { didSet { scheduleStaleFiles() } }
    /// Computed off the main thread: needs Spotlight per file.
    var staleList: [FileEntry] = []
    /// Bundle IDs of apps found running at the last check (one `ps` call for all apps).
    var runningBundles: Set<String> = []
    var orphanSizes: [String: Int64] = [:]
    /// Operations with a queued or running job, so their buttons stay disabled meanwhile.
    var busyOps: Set<Int64> = []
    var cleanupCandidates: [CleanupCandidate] = []
    /// Bundle ID the cleanup list is narrowed to, set from the app table.
    var cleanupFilter: String?
    var cleanupPreviews: [String: String] = [:]
    /// Groups queued or being cleaned; their buttons stay disabled.
    var cleanupRunning: Set<String> = []
    /// Selected app (bundle ID) on the Apps screen.
    var appsSelection: String?
    var eligibility: [String: ArchiveEligibility] = [:]
    var archivedApps: [LedgerOperation] = []
    private var staleTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var holdingBytesGeneration = 0
    var hasFullDiskAccess = true
    var hasTimeMachine: Bool?

    var holdDays: Int {
        get { Int((try? ledger.setting("hold.days")) ?? nil ?? "") ?? 7 }
        set { try? ledger.setSetting("hold.days", String(newValue)) }
    }

    var savedKhoUUID: String? { (try? ledger.setting("kho.uuid")) ?? nil }

    var internalVolume: VolumeInfo? { volumes.first(where: \.isRoot) }

    var khoVolume: VolumeInfo? {
        guard let kho else { return nil }
        return volumes.first { $0.uuid == kho.uuid }
    }

    var externalVolumes: [VolumeInfo] { volumes.filter { !$0.isRoot } }

    var holdingNeedsAttention: Bool {
        holdingBytes > Self.holdingWarnBytes || (internalVolume?.availableForImportant ?? .max) < Self.lowSpaceBytes
    }

    var runningJob: JobSnapshot? { jobs.first { $0.state == .running } }

    static let scanAppsTitle = "Quét ứng dụng"
    static let scanFolderPrefix = "Quét thư mục "

    func hasActiveJob(_ matches: (String) -> Bool) -> Bool {
        jobs.contains { ($0.state == .running || $0.state == .queued) && matches($0.title) }
    }

    var isScanningApps: Bool { hasActiveJob { $0 == Self.scanAppsTitle } }
    var isScanningFolder: Bool { hasActiveJob { $0.hasPrefix(Self.scanFolderPrefix) } }

    func notify(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { self?.notice = nil }
        }
    }

    // MARK: Startup

    /// Exits when another Switch Kho already holds the lock (after bringing it forward).
    static func launch() -> AppModel {
        let dataDir = dataDirectory()
        try? FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        guard let lock = InstanceLock.acquire(at: dataDir.appendingPathComponent(".lock")) else {
            let me = Bundle.main.bundleIdentifier ?? "local.switchkho.app"
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: me)
            where app.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                app.activate()
            }
            exit(0)
        }
        do {
            return try AppModel(dataDir: dataDir, lock: lock)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Không mở được sổ cái Switch Kho"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            exit(1)
        }
    }

    static func dataDirectory() -> URL {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--data-dir"), i + 1 < args.count {
            return URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/SwitchKho")
    }

    private init(dataDir: URL, lock: InstanceLock) throws {
        self.dataDir = dataDir
        self.lock = lock
        ledger = try Ledger(path: dataDir.appendingPathComponent("ledger.sqlite"))
        holding = HoldingArea(root: dataDir.appendingPathComponent("Holding"))
        linkRoot = dataDir.appendingPathComponent("KhoLink")
        let khoCell = self.khoCell, appIndex = self.appIndex, ledger = self.ledger
        // Opened before the service, which reports every change on the Kho to it.
        catalog = try Self.openCatalog(dataDir.appendingPathComponent("catalog.sqlite"))
        let catalogHook = CatalogSync.makeHook(
            store: catalog, queue: jobQueue,
            khoUUID: { khoCell.value.withLock { $0?.uuid } },
            khoRoot: { khoCell.value.withLock { $0?.layout.khoRoot } })
        offloadService = OffloadService(
            ledger: ledger, holding: holding, policy: policy, copier: copier, linkRoot: linkRoot,
            mountedKho: { khoCell.value.withLock { $0 } },
            holdDays: { Int((try? ledger.setting("hold.days")) ?? nil ?? "") ?? 7 },
            now: { Date() },
            appRunning: { bundleID in
                // Before the first scan the index is empty; helpers must still be seen.
                let url = appIndex.value.withLock { $0[bundleID] }
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
                return RunningProcesses.isRunning(bundleID: bundleID, appURL: url)
            },
            onKhoChanged: catalogHook)

        observeJobs()
        refreshVolumes()
        enqueueRecoverAndCommit()
        observeWorkspace()
        liveGuard = LiveGuard(model: self)
        liveGuard?.start()
        Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enqueueAutoRules() }
        }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.enqueueCommitDue() }
        }
        checkEnvironment()
    }

    private func observeJobs() {
        Task { [weak self, jobQueue] in
            for await snapshot in await jobQueue.updates {
                guard let self else { return }
                let finished = self.jobs.filter { $0.state == .running }.map(\.id)
                self.jobs = snapshot
                if snapshot.contains(where: { finished.contains($0.id) && $0.state != .running }) {
                    self.refreshOperations()
                }
            }
        }
    }

    private func observeWorkspace() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification, NSWorkspace.didWakeNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.refreshVolumes()
                    if name == NSWorkspace.didWakeNotification { self?.liveGuard?.didWake() }
                }
            }
        }
    }

    func checkEnvironment() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        hasFullDiskAccess = FileManager.default.isReadableFile(atPath: "\(home)/Library/Safari/Bookmarks.plist")
            || (try? FileManager.default.contentsOfDirectory(atPath: "\(home)/Library/Safari")) != nil
        Task.detached {
            let tm = VolumeService.hasTimeMachineDestination()
            await MainActor.run { self.hasTimeMachine = tm }
        }
    }

    // MARK: Volumes and Kho

    func refreshVolumes() {
        volumes = VolumeService.mountedVolumes()
        // A failed read must not look like "Kho gone": the guard would stop apps for nothing.
        let savedUUID: String?, savedToken: String?
        do {
            savedUUID = try ledger.setting("kho.uuid")
            savedToken = try ledger.setting("kho.token")
        } catch {
            lastError = "Không đọc được cài đặt Kho: \(error.localizedDescription)"
            return
        }
        let wasMounted = kho != nil
        let confirmed = KhoIdentity.confirm(volumes: volumes, savedUUID: savedUUID, savedToken: savedToken,
                                            linkRoot: linkRoot)
        kho = confirmed
        khoCell.value.withLock { $0 = confirmed }
        khoProblem = KhoIdentity.mismatchReason(volumes: volumes, savedUUID: savedUUID, savedToken: savedToken)
        do {
            try KhoLink.update(linkRoot: linkRoot, kho: confirmed)
        } catch {
            lastError = error.localizedDescription
        }
        if !wasMounted && confirmed != nil {
            enqueueRecoverAndCommit()
            indexKhoIfStale()
            enqueueAutoRules()
        }
        refreshOperations()
        liveGuard?.volumesChanged(wasMounted: wasMounted, isMounted: confirmed != nil)
    }

    func adopt(_ volume: VolumeInfo) {
        do {
            let (mounted, token) = try KhoIdentity.adopt(volume, linkRoot: linkRoot)
            try ledger.setSetting("kho.uuid", mounted.uuid)
            try ledger.setSetting("kho.token", token)
            ledger.log(action: "Đã chọn Kho", path: volume.url.path, detail: volume.name, ok: true)
            refreshVolumes()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func volumeHasLedgerBackup(_ volume: VolumeInfo) -> Bool { KhoIdentity.hasLedgerBackup(volume) }

    var ledgerIsEmpty: Bool { ((try? ledger.operationCount()) ?? 0) == 0 }

    func eject() {
        Task { await guardedEject() }
    }

    /// Classifies every guarded link, puts lost locks back, and records the result.
    func checkLiveIntegrity() {
        guard let guardian = liveGuard else { return }
        guard let ops = guardian.liveOperations() else { return }
        let ledger = self.ledger
        let layout = kho?.layout ?? KhoLayout(khoRoot: URL(fileURLWithPath: "/nonexistent"), linkRoot: linkRoot)
        let mounted = kho != nil
        Task.detached { [weak self] in
            var out: [Int64: [LiveStatus]] = [:]
            for op in ops {
                let items = LiveIntegrity.items(of: op, ledger: ledger, layout: layout)
                let statuses = LiveIntegrity.check(items: items, khoMounted: mounted)
                for (item, status) in zip(items, statuses) where status == .ok {
                    LiveIntegrity.relockIfNeeded(item.original)
                }
                out[op.id] = statuses
                let bad = statuses.filter { $0 != .ok && $0 != .khoMissing }
                if !bad.isEmpty { ledger.log(action: "Liên kết Kho có vấn đề", path: op.title, detail: "\(bad)", ok: false) }
            }
            await self?.setLiveIssues(out)
        }
    }

    func setLiveIssues(_ issues: [Int64: [LiveStatus]]) { liveIssues = issues }

    // MARK: Jobs

    func enqueueRecoverAndCommit() {
        let service = offloadService
        Task {
            await jobQueue.enqueue(title: "Kiểm tra và dọn vùng chờ", cancellable: true) { [weak self] ctx in
                let report = service.recover()
                await self?.setRecoveryReport(report)
                if ctx.isCancelled { throw CancellationError() }
                service.commitDue(progress: { p in
                    ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                               detail: "Đang kiểm \(p.currentName)")
                }, isCancelled: { ctx.isCancelled })
                if ctx.isCancelled { throw CancellationError() }
                await self?.backupLedgerIfSafe()
            }
        }
    }

    func setRecoveryReport(_ r: RecoveryReport) {
        recoveryReport = r
        refreshOperations()
        let holding = self.holding, names = r.orphanHoldingDirs
        Task.detached { [weak self] in
            let sizes = Dictionary(uniqueKeysWithValues: names.map {
                ($0, DirectoryScanner.size(of: holding.root.appendingPathComponent($0)))
            })
            await self?.setOrphanSizes(sizes)
        }
    }

    func setOrphanSizes(_ sizes: [String: Int64]) { orphanSizes = sizes }
    func setAppDataMap(_ m: AppDataMap, running: Set<String>) { appDataMap = m; runningBundles = running }
    func setRunningBundles(_ r: Set<String>) { runningBundles = r }
    func setFolderScan(_ r: ScanResult) {
        folderScan = r
        folderPath = []
        scheduleStaleFiles()
    }
    func setStaleList(_ list: [FileEntry]) { staleList = list }

    func enqueueCommitDue() {
        let service = offloadService
        Task {
            await jobQueue.enqueue(title: "Dọn vùng chờ đã đến hạn", cancellable: true) { [weak self] ctx in
                service.commitDue(progress: { p in
                    ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                               detail: "Đang kiểm \(p.currentName)")
                }, isCancelled: { ctx.isCancelled })
                await self?.backupLedgerIfSafe()
            }
        }
    }

    /// Never backs up an empty ledger, and never replaces a backup that knows more operations.
    func backupLedgerIfSafe() {
        guard let kho else { return }
        guard ((try? ledger.operationCount()) ?? 0) > 0 else { return }
        do {
            try ledger.backup(to: kho.layout.ledgerBackup)
        } catch KhoError.invalidState(let message) {
            offerLedgerRestore = true
            ledger.log(action: "Không sao lưu sổ cái", path: kho.layout.ledgerBackup.path, detail: message, ok: false)
        } catch {
            ledger.log(action: "Không sao lưu sổ cái", path: kho.layout.ledgerBackup.path,
                       detail: error.localizedDescription, ok: false)
        }
    }

    /// Runs a state-changing operation through the queue, then backs up the ledger.
    func runOperation(_ title: String, opID: Int64, done: String,
                      _ body: @escaping @Sendable (OffloadService, JobContext) throws -> Void) {
        let service = offloadService
        busyOps.insert(opID)
        Task {
            do {
                try await jobQueue.run(title: title) { ctx in try body(service, ctx) }
                notify(done)
            } catch is CancellationError {
                notify("Đã huỷ: \(title)")
            } catch {
                lastError = "\(title): \(error.localizedDescription)"
            }
            busyOps.remove(opID)
            backupLedgerIfSafe()
            refreshOperations()
        }
    }

    func undo(_ opID: Int64) {
        runOperation("Hoàn tác #\(opID)", opID: opID, done: "Đã hoàn tác #\(opID), dữ liệu đã về chỗ cũ") { s, ctx in try s.undo(opID: opID, isCancelled: { ctx.isCancelled }) }
    }

    func commitNow(_ opID: Int64) {
        runOperation("Xoá vùng chờ #\(opID)", opID: opID, done: "Đã xoá vùng chờ #\(opID)") { s, ctx in
            try s.commitNow(opID: opID, progress: { p in
                ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                           detail: p.currentName)
            }, isCancelled: { ctx.isCancelled })
        }
    }

    func retry(_ row: HoldingRow) {
        switch row.op.state {
        case .restoring, .committed:
            runOperation("Lấy về #\(row.op.id)", opID: row.op.id, done: "Đã lấy về #\(row.op.id)") { s, _ in try s.restore(opID: row.op.id) }
        case .undoing:
            undo(row.op.id)
        default:
            enqueueRecoverAndCommit()
        }
    }

    func acceptKhoCopy(_ opID: Int64) {
        runOperation("Chấp nhận bản trên Kho #\(opID)", opID: opID,
                     done: "Đã chấp nhận bản trên Kho cho #\(opID)") { s, ctx in
            try s.acceptKhoCopy(opID: opID, isCancelled: { ctx.isCancelled })
        }
    }

    func markReviewed(_ opID: Int64) {
        try? ledger.setNeedsReview(opID, false)
        ledger.log(action: "Đánh dấu đã kiểm", path: nil, detail: "#\(opID)", ok: true)
        refreshOperations()
    }

    func cancelRunningJob() {
        Task { _ = await jobQueue.cancelRunningIfCancellable() }
    }

    func refreshOperations() {
        let states: Set<OperationState> = [.moving, .holding, .undoing, .restoring, .committing]
        let ops = ((try? ledger.operations()) ?? []).filter { states.contains($0.state) || $0.needsReview }
        let now = Date()
        holdingRows = ops.map { op in
            let items = (try? ledger.items(op.id)) ?? []
            return HoldingRow(op: op, items: items,
                              bytes: items.reduce(0) { $0 + ($1.allocated ?? 0) },
                              overdue: op.state == .holding && (op.holdingUntil ?? .distantFuture) <= now)
        }
        personalArchives = ((try? ledger.operations()) ?? []).filter {
            $0.kind == .personal && [.holding, .committed, .undoing, .restoring].contains($0.state)
        }
        archivedApps = ((try? ledger.operations()) ?? []).filter {
            $0.kind == .appCold && [.holding, .committed, .undoing, .restoring, .committing].contains($0.state)
        }
        // Walking the holding area can take a while; never on the main thread.
        holdingBytesGeneration += 1
        let generation = holdingBytesGeneration, holding = self.holding
        Task.detached { [weak self] in
            let bytes = holding.pendingBytes()
            await self?.setHoldingBytes(bytes, generation: generation)
        }
    }

    func setHoldingBytes(_ bytes: Int64, generation: Int) {
        if generation == holdingBytesGeneration { holdingBytes = bytes }
    }

    func reveal(_ row: HoldingRow) {
        var urls: [URL] = [holding.root.appendingPathComponent(row.op.uid)]
        if let kho, kho.uuid == row.op.khoUUID {
            urls += row.items.compactMap { $0.khoRelPath }.compactMap { try? kho.layout.absoluteURL(relative: $0) }
        }
        NSWorkspace.shared.activateFileViewerSelecting(urls.filter { FileManager.default.fileExists(atPath: $0.path) })
    }

    func revealOrphan(_ name: String) {
        NSWorkspace.shared.activateFileViewerSelecting([holding.root.appendingPathComponent(name)])
    }

    func orphanSize(_ name: String) -> Int64? { orphanSizes[name] }

    // MARK: Analyzer

    func scanApps() {
        let ledger = self.ledger, appIndex = self.appIndex
        Task {
            await jobQueue.enqueue(title: Self.scanAppsTitle, cancellable: true) { [weak self] ctx in
                ctx.report(fraction: 0.05, detail: "Đọc danh sách ứng dụng")
                let apps = AppCatalog.scan()
                appIndex.value.withLock { $0 = Dictionary(apps.map { ($0.bundleID, $0.url) }, uniquingKeysWith: { a, _ in a }) }
                if ctx.isCancelled { throw CancellationError() }
                ctx.report(fraction: 0.2, detail: "Đo dữ liệu trong Thư viện")
                let raw = (try? ledger.settings(withPrefix: "appdata.override.")) ?? [:]
                let overrides = Dictionary(raw.map { (String($0.key.dropFirst("appdata.override.".count)), $0.value) },
                                           uniquingKeysWith: { a, _ in a })
                let map = AppDataMapper.map(home: FileManager.default.homeDirectoryForCurrentUser,
                                            apps: apps, overrides: overrides)
                ctx.report(fraction: 0.95, detail: "Kiểm ứng dụng đang chạy")
                let running = Self.runningBundleIDs(map.footprints.map(\.app))
                await self?.setAppDataMap(map, running: running)
            }
        }
    }

    func assign(_ folder: AppDataFolder, to bundleID: String) {
        try? ledger.setSetting("appdata.override.\(folder.url.path)", bundleID)
        scanApps()
    }

    func isRunning(_ app: InstalledApp) -> Bool { runningBundles.contains(app.bundleID) }

    /// One process listing for all apps; safe to call off the main thread.
    nonisolated static func runningBundleIDs(_ apps: [InstalledApp]) -> Set<String> {
        let paths = RunningProcesses.executablePaths()
        return Set(apps.filter { app in
            !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
                || RunningProcesses.isRunning(appURL: app.url, paths: paths)
        }.map(\.bundleID))
    }

    func refreshRunning() {
        guard let apps = appDataMap?.footprints.map(\.app) else { return }
        Task.detached { [weak self] in
            let running = Self.runningBundleIDs(apps)
            await self?.setRunningBundles(running)
        }
    }

    func scanFolder(_ url: URL) {
        Task {
            await jobQueue.enqueue(title: Self.scanFolderPrefix + url.lastPathComponent, cancellable: true) { [weak self] ctx in
                let result = try DirectoryScanner().scan(url, progress: { n in
                    ctx.report(fraction: 0, detail: "\(n) file")
                }, isCancelled: { ctx.isCancelled })
                await self?.setFolderScan(result)
            }
        }
    }

    /// Recomputes the stale list in the background, waiting briefly so stepper clicks coalesce.
    func scheduleStaleFiles() {
        staleTask?.cancel()
        guard let scan = folderScan else { staleList = []; return }
        let days = staleDays
        staleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            if Task.isCancelled { return }
            let list = await Task.detached {
                DirectoryScanner.staleFiles(in: scan, days: days, minSize: 10 << 20)
            }.value
            if !Task.isCancelled { self?.setStaleList(list) }
        }
    }

    /// Writes the space budget table as Markdown to a file the user picks.
    func exportBudget() {
        guard let map = appDataMap else {
            lastError = "Hãy quét ứng dụng trước khi xuất ngân sách."
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "space-budget.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let stale = staleList.reduce(Int64(0)) { $0 + $1.size }
        Task {
            do {
                try await jobQueue.run(title: "Xuất ngân sách dung lượng") { _ in
                    let home = FileManager.default.homeDirectoryForCurrentUser
                    let caches = map.unassigned.filter(\.area.isCache).reduce(Int64(0)) { $0 + $1.allocated }
                    let pkg = [".npm/_cacache", ".cache/huggingface", ".cache/pip", ".cache/uv", ".cache/pnpm"]
                        .reduce(Int64(0)) { $0 + DirectoryScanner.size(of: home.appendingPathComponent($1)) }
                    let lines = SpaceBudget.estimate(map: map, caches: caches, personalStale: stale, packageCache: pkg)
                    try SpaceBudget.markdown(lines).write(to: url, atomically: true, encoding: .utf8)
                }
                notify("Đã xuất ngân sách ra \(url.lastPathComponent)")
            } catch {
                lastError = "Xuất ngân sách: \(error.localizedDescription)"
            }
        }
    }
}
