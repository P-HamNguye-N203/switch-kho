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
    let linkRoot: URL
    private let khoCell = KhoCell()
    private let appIndex = AppIndexCell()
    private let lock: InstanceLock

    var volumes: [VolumeInfo] = []
    var kho: MountedKho?
    var khoProblem: String?
    var jobs: [JobSnapshot] = []
    var appDataMap: AppDataMap?
    var recoveryReport: RecoveryReport?
    var offerLedgerRestore = false
    var holdingRows: [HoldingRow] = []
    var holdingBytes: Int64 = 0
    var lastError: String?
    var folderScan: ScanResult?
    var staleDays = 180
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
        offloadService = OffloadService(
            ledger: ledger, holding: holding, policy: policy, copier: copier,
            mountedKho: { khoCell.value.withLock { $0 } },
            holdDays: { Int((try? ledger.setting("hold.days")) ?? nil ?? "") ?? 7 },
            now: { Date() },
            appRunning: { bundleID in
                RunningProcesses.isRunning(bundleID: bundleID, appURL: appIndex.value.withLock { $0[bundleID] })
            })

        observeJobs()
        refreshVolumes()
        enqueueRecoverAndCommit()
        observeWorkspace()
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
                Task { @MainActor in self?.refreshVolumes() }
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
        let savedUUID = savedKhoUUID
        let savedToken = (try? ledger.setting("kho.token")) ?? nil
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
        if !wasMounted && confirmed != nil { enqueueRecoverAndCommit() }
        refreshOperations()
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
        guard let v = khoVolume else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: v.url)
        } catch {
            lastError = "Không Eject được: \(error.localizedDescription)"
        }
        refreshVolumes()
    }

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

    func setRecoveryReport(_ r: RecoveryReport) { recoveryReport = r; refreshOperations() }
    func setAppDataMap(_ m: AppDataMap) { appDataMap = m }
    func setFolderScan(_ r: ScanResult) { folderScan = r }

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
    func runOperation(_ title: String, _ body: @escaping @Sendable (OffloadService, JobContext) throws -> Void) {
        let service = offloadService
        Task {
            do {
                try await jobQueue.run(title: title) { ctx in try body(service, ctx) }
            } catch {
                lastError = error.localizedDescription
            }
            backupLedgerIfSafe()
            refreshOperations()
        }
    }

    func undo(_ opID: Int64) {
        runOperation("Hoàn tác #\(opID)") { s, ctx in try s.undo(opID: opID, isCancelled: { ctx.isCancelled }) }
    }

    func commitNow(_ opID: Int64) {
        runOperation("Xoá vùng chờ #\(opID)") { s, ctx in
            try s.commitNow(opID: opID, progress: { p in
                ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                           detail: p.currentName)
            }, isCancelled: { ctx.isCancelled })
        }
    }

    func retry(_ row: HoldingRow) {
        switch row.op.state {
        case .restoring, .committed:
            runOperation("Lấy về #\(row.op.id)") { s, _ in try s.restore(opID: row.op.id) }
        case .undoing:
            undo(row.op.id)
        default:
            enqueueRecoverAndCommit()
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
        holdingBytes = holding.pendingBytes()
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

    func orphanSize(_ name: String) -> Int64 {
        DirectoryScanner.size(of: holding.root.appendingPathComponent(name))
    }

    // MARK: Analyzer

    func scanApps() {
        let ledger = self.ledger, appIndex = self.appIndex
        Task {
            await jobQueue.enqueue(title: "Quét ứng dụng", cancellable: true) { [weak self] ctx in
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
                await self?.setAppDataMap(map)
            }
        }
    }

    func assign(_ folder: AppDataFolder, to bundleID: String) {
        try? ledger.setSetting("appdata.override.\(folder.url.path)", bundleID)
        scanApps()
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        RunningProcesses.isRunning(bundleID: app.bundleID, appURL: app.url)
    }

    func scanFolder(_ url: URL) {
        Task {
            await jobQueue.enqueue(title: "Quét \(url.lastPathComponent)", cancellable: true) { [weak self] ctx in
                let result = try DirectoryScanner().scan(url, progress: { n in
                    ctx.report(fraction: 0, detail: "\(n) file")
                }, isCancelled: { ctx.isCancelled })
                await self?.setFolderScan(result)
            }
        }
    }

    func staleFiles() -> [FileEntry] {
        guard let folderScan else { return [] }
        return DirectoryScanner.staleFiles(in: folderScan, days: staleDays, minSize: 10 << 20)
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
        let stale = staleFiles().reduce(Int64(0)) { $0 + $1.size }
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
            } catch {
                lastError = error.localizedDescription
            }
        }
    }
}
