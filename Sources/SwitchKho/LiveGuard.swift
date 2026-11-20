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
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        handle(.guardStarted(runningBundleIDs: running))
        updateTimer()
    }

    /// Operations still guarded: every live operation with an item not yet brought back.
    func liveOperations() -> [LedgerOperation] {
        guard let ledger = model?.ledger else { return [] }
        let states: Set<OperationState> = [.copying, .moving, .holding, .committing, .committed, .undoing, .restoring]
        return ((try? ledger.operations(states: states)) ?? []).filter { op in
            op.kind == .appLive && ((try? ledger.items(op.id)) ?? []).contains { $0.role == .normal && !$0.restored }
        }
    }

    func reloadLiveApps() {
        var apps: [String: URL] = [:]
        for op in liveOperations() {
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

    private func updateTimer() {
        let needed = model?.kho == nil && !liveApps.isEmpty
        if needed, timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.handle(.tick) }
            }
        } else if !needed {
            timer?.invalidate()
            timer = nil
        }
    }

    private func terminate(_ ids: [String], reason: String) {
        guard let model else { return }
        var stopped: [String] = []
        for id in ids {
            var hit = false
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                app.forceTerminate()
                hit = true
            }
            // Helpers and background processes are not always NSRunningApplications.
            if let url = liveApps[id] {
                for pid in RunningProcesses.pids(inside: url) where pid != getpid() {
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
