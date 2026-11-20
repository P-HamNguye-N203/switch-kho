import AppKit
import KhoCore

extension AppModel {
    var leaveSymlinkByDefault: Bool {
        get { ((try? ledger.setting("personal.leaveSymlink")) ?? nil) == "1" }
        set { try? ledger.setSetting("personal.leaveSymlink", newValue ? "1" : "0") }
    }

    var ledgerURL: URL { dataDir.appendingPathComponent("ledger.sqlite") }

    /// Restoring replaces the ledger file, so it only happens while this Mac's ledger is empty.
    func canRestoreLedger(from volume: VolumeInfo) -> Bool { ledgerIsEmpty && volumeHasLedgerBackup(volume) }

    /// Stops all work, swaps in the backup from the Kho, then quits: the next launch opens
    /// the restored ledger and recognises the Kho from the identity saved in it.
    func restoreLedger(from volume: VolumeInfo) async {
        guard canRestoreLedger(from: volume) else { return }
        await jobQueue.suspend()
        guard await jobQueue.waitUntilIdle(timeout: .seconds(30)) else {
            await jobQueue.resume()
            lastError = "Đang có công việc chạy, hãy chờ xong rồi thử lại."
            return
        }
        let backup = KhoLayout(khoRoot: volume.url, linkRoot: linkRoot).ledgerBackup
        ledger.close()
        let alert = NSAlert()
        do {
            try Ledger.restoreFromBackup(backup, to: ledgerURL)
            alert.messageText = "Đã khôi phục sổ cái. Hãy mở lại Switch Kho."
        } catch {
            alert.messageText = "Không khôi phục được sổ cái"
            alert.informativeText = error.localizedDescription + "\nHãy mở lại Switch Kho."
        }
        alert.runModal()
        quitWithoutWarning()
    }

    func quitWithoutWarning() {
        AppDelegate.skipQuitWarning = true
        NSApp.terminate(nil)
    }

    func openPrivacySettings(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Copies between this Mac and the Kho without removing the source.
    func copyOnly(_ urls: [URL], into folder: URL) {
        let service = offloadService
        let title = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) mục"
        Task {
            do {
                try await jobQueue.run(title: "Chép \(title)", cancellable: true) { ctx in
                    for url in urls {
                        try service.copyOnly(url, intoFolder: folder, progress: { p in
                            ctx.report(fraction: p.bytesTotal > 0 ? Double(p.bytesDone) / Double(p.bytesTotal) : 0,
                                       detail: p.currentName)
                        }, isCancelled: { ctx.isCancelled })
                    }
                }
                notify("Đã chép \(title)")
            } catch is CancellationError {
                notify("Đã huỷ chép \(title)")
            } catch {
                lastError = "Chép \(title): \(error.localizedDescription)"
            }
            filesGeneration += 1
        }
    }

    /// The archive operation a file under `SwitchKho/Archive` came from, if the ledger knows it.
    func archiveOperation(forKhoURL url: URL) -> LedgerOperation? {
        guard let rel = kho?.layout.relativePath(url) else { return nil }
        return operation(forRelPath: rel)
    }
}

/// Hides the window when opened at login and warns before quitting while apps run from the Kho.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var skipQuitWarning = false
    @MainActor static var launchedAtLogin = false
    @MainActor static weak var model: AppModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        // Recorded so a real login shows whether macOS sent the signal at all.
        Self.model?.ledger.log(action: "Khởi động", path: nil,
                               detail: atLogin ? "mở cùng máy" : "mở bằng tay", ok: true)
        guard atLogin else { return }
        Self.launchedAtLogin = true
        // The window may already be up; the view hides it when it appears later instead.
        for window in NSApp.windows where window.identifier?.rawValue.hasPrefix("main") == true {
            window.close()
            Self.launchedAtLogin = false
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !Self.skipQuitWarning, let model = Self.model, !(model.liveGuard?.liveApps.isEmpty ?? true) else {
            return .terminateNow
        }
        // Log out, restart and shut down carry a quit reason; never hold those up.
        if NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason) != nil {
            return .terminateNow
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Thoát Switch Kho?"
        alert.informativeText = "Có app đang chạy từ Kho. Khi Switch Kho không chạy, người gác không tắt các app đó nếu Kho bị rút, và chúng không đọc được dữ liệu cho tới khi Switch Kho mở lại."
        alert.addButton(withTitle: "Ở lại")
        alert.addButton(withTitle: "Thoát")
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
