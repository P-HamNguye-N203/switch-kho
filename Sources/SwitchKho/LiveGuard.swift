import AppKit
import KhoCore

/// Stops apps running from the Kho when the Kho goes away, and checks their links when it
/// comes back. Reacts after the fact (workspace notifications plus a 5 s poll while the Kho
/// is away); it only works while Switch Kho runs, hence the login item.
@MainActor final class LiveGuard {
    private weak var model: AppModel?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// bundleID → app URL of every app whose data lives on the Kho.
    private(set) var liveApps: [String: URL] = [:]

    init(model: AppModel) {
        self.model = model
        reloadLiveApps()
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let id = app?.bundleIdentifier
            Task { @MainActor in if let id { self?.handle(.appLaunched(bundleID: id)) } }
        })
        observers.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                // Only the confirmed Kho's own volume counts.
                guard let self, let kho = self.model?.khoVolume, let url, FileOps.same(url, kho.url) else { return }
                self.handle(.khoWillUnmount)
            }
        })
    }

    /// Called once the model holds this guard, so integrity checks can reach it.
    func start() {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        handle(.guardStarted(runningBundleIDs: running))
        updateTimer()
    }

    /// Operations still guarded: every live operation with an item not yet brought back.
    /// nil when the ledger could not be read: the caller keeps what it had instead of
    /// dropping its guard.
    func liveOperations() -> [LedgerOperation]? {
        guard let ledger = model?.ledger else { return nil }
        let states: Set<OperationState> = [.copying, .moving, .holding, .committing, .committed, .undoing, .restoring]
        do {
            var out: [LedgerOperation] = []
            for op in try ledger.operations(states: states) where op.kind == .appLive {
                if try ledger.items(op.id).contains(where: {
                    $0.role == .normal && !$0.restored && !$0.released && $0.stage != .swapped
                }) { out.append(op) }
            }
            return out
        } catch {
            ledger.log(action: "Người gác không đọc được sổ cái", path: nil, detail: error.localizedDescription, ok: false)
            return nil
        }
    }

    func reloadLiveApps() {
        guard let ops = liveOperations() else { return }
        var apps: [String: URL] = [:]
        for op in ops {
            guard let id = op.bundleID else { continue }
            // Not only from the last scan: at login the app list is still empty.
            apps[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
                ?? model?.appDataMap?.footprints.first { $0.app.bundleID == id }?.app.url
        }
        liveApps = apps
        updateTimer()
    }

    /// Called by the model after volumes were refreshed, with the Kho state before and after.
    func volumesChanged(wasMounted: Bool, isMounted: Bool) {
        if wasMounted && !isMounted { handle(.khoDidUnmount) }
        if !wasMounted && isMounted { handle(.khoDidMount) }
        updateTimer()
    }

    func didWake() { handle(.didWake) }

    func handle(_ event: GuardEvent) {
        guard let model else { return }
        let action = LiveGuardPolicy.decide(event, liveBundleIDs: Set(liveApps.keys), khoMounted: model.kho != nil)
        switch action {
        case .terminate(let ids, let reason): terminate(ids, reason: reason)
        case .checkIntegrity: model.checkLiveIntegrity()
        case .none: break
        }
    }

    /// Runs whenever apps live on the Kho. With the Kho away it stops them; with the Kho
    /// present it checks the Kho is really still there, in case the unmount went unnoticed.
    private func updateTimer() {
        let needed = !liveApps.isEmpty
        if needed, timer == nil {
            let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.pulse() }
            }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    private func pulse() {
        guard let model else { return }
        guard let identity = model.kho?.layout.identityFile else {
            handle(.tick)
            return
        }
        Task.detached {
            let present = FileOps.exists(identity)
            if !present { await MainActor.run { model.refreshVolumes() } }
        }
    }

    private func terminate(_ ids: [String], reason: String) {
        guard let model else { return }
        var stopped: [String] = []
        let processes = RunningProcesses.processes()
        for id in ids {
            var hit = false
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                app.forceTerminate()
                hit = true
            }
            // Helpers and background processes are not always NSRunningApplications.
            if let url = liveApps[id] {
                for pid in RunningProcesses.pids(inside: url, processes: processes) where pid != getpid() {
                    kill(pid, SIGKILL)
                    hit = true
                }
            }
            if hit { stopped.append(liveApps[id]?.deletingPathExtension().lastPathComponent ?? id) }
        }
        guard !stopped.isEmpty else { return }
        let message = "Đã tắt \(stopped.joined(separator: ", ")): \(reason)"
        let ledger = model.ledger
        Task.detached { ledger.log(action: "guard", path: ids.joined(separator: ","), detail: reason, ok: true) }
        model.guardNotice = message
    }
}
