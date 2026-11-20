import AppKit
import KhoCore

extension AppModel {
    /// Ejects the Kho only after copy jobs stopped and every app running from it has quit.
    func guardedEject() async {
        guard let volume = khoVolume else { return }
        // No new job (scheduled ones included) may start on the Kho while it is being ejected.
        await jobQueue.suspend()
        defer { Task { await jobQueue.resume() } }
        _ = await jobQueue.cancelRunningIfCancellable()
        guard await jobQueue.waitUntilIdle(timeout: .seconds(10)) else {
            lastError = "Đang có thao tác chép dữ liệu, hãy chờ xong rồi Eject."
            return
        }
        let live = liveGuard?.liveApps ?? [:]
        let running = live.filter { id, url in RunningProcesses.isRunning(bundleID: id, appURL: url) }
        for (id, _) in running {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) { app.terminate() }
        }
        let deadline = Date().addingTimeInterval(15)
        var still = running
        while !still.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(500))
            still = still.filter { id, url in RunningProcesses.isRunning(bundleID: id, appURL: url) }
        }
        if let (id, url) = still.first {
            lastError = "Hãy tự thoát \(url.deletingPathExtension().lastPathComponent) rồi thử lại (\(id))."
            return
        }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: volume.url)
            ledger.log(action: "Eject Kho", path: volume.url.path, detail: nil, ok: true)
            notify("Đã tháo Kho an toàn")
        } catch {
            ledger.log(action: "Eject Kho", path: volume.url.path, detail: error.localizedDescription, ok: false)
            lastError = "Không Eject được: \(error.localizedDescription)"
        }
        refreshVolumes()
    }
}
