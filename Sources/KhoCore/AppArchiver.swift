import CoreServices
import Darwin
import Foundation

public struct ArchiveEligibility: Sendable, Equatable {
    public var blockers: [String] = []
    public var warnings: [String] = []
    public var allowed: Bool { blockers.isEmpty }
}

public struct AppRestoreResult: Sendable {
    /// The signature verified before archiving but not after coming back.
    public let signatureBroken: Bool
    /// Items that came back beside their old place because something new sat there.
    public var relocated: [String] = []
}

/// Archives a whole app (bundle plus every data folder assigned to it) to the Kho, and
/// brings it back.
public enum AppArchiver {
    static let codesign = URL(fileURLWithPath: "/usr/bin/codesign")

    public static func eligibility(for fp: AppFootprint, isRunning: Bool, ledger: Ledger,
                                   home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                   otherApps: [InstalledApp] = []) -> ArchiveEligibility {
        var e = ArchiveEligibility()
        let app = fp.app
        if app.isAppStore { e.blockers.append("Ứng dụng từ App Store — cập nhật sẽ hỏng") }
        if app.ownerIsRoot { e.blockers.append("Thuộc quyền hệ thống (root)") }
        if isRunning { e.blockers.append("Đang chạy — hãy thoát trước") }
        if FileOps.components(app.url.path).first == "System" { e.blockers.append("Ứng dụng hệ thống") }
        if hasForeignOwner(app.url) { e.blockers.append("Có file trong bundle không thuộc tài khoản của bạn") }
        for url in [app.url] + fp.folders.map(\.url) {
            if let (op, _) = (try? ledger.activeItems(overlapping: url.path))?.first {
                e.blockers.append("Dữ liệu đang thuộc thao tác #\(op.id) (ví dụ đang chạy từ Kho)")
                break
            }
        }
        for folder in fp.folders where folder.area == .groupContainers {
            let shared = sharedGroupContainer(folder.url.lastPathComponent, owner: app, others: otherApps)
            if let other = shared {
                e.blockers.append("\(folder.url.lastPathComponent) dùng chung với \(other.name)")
            }
        }

        if app.hasSparkle { e.warnings.append("Có trình tự cập nhật Sparkle — hãy cập nhật sau khi lấy về") }
        if app.isAdobe { e.warnings.append("Ứng dụng Adobe — có thể cần cài lại") }
        if fp.folders.contains(where: { $0.area == .containers }) {
            e.warnings.append("Dữ liệu sandbox (Containers) sẽ mất lớp bảo vệ App Data của macOS khi nằm trong vùng chờ và trên Kho")
        }
        if let agent = launchAgent(pointingInto: app.url, home: home) {
            e.warnings.append("\(agent) chạy nền và sẽ báo lỗi hoặc tạo lại dữ liệu khi app vắng mặt — hãy tắt nó trước")
        }
        return e
    }

    /// The first item in the bundle owned by someone else; files restored from the Kho
    /// (mounted with owners ignored) would come back with the wrong owner.
    static func hasForeignOwner(_ bundle: URL) -> Bool {
        let uid = getuid()
        var st = stat()
        if lstat(bundle.path, &st) == 0, st.st_uid != uid { return true }
        guard let walker = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: nil,
                                                          options: [], errorHandler: { _, _ in true })
        else { return false }
        for case let url as URL in walker {
            if lstat(url.path, &st) == 0, st.st_uid != uid { return true }
        }
        return false
    }

    /// Group containers are named "<TEAMID>.<group>"; another installed app whose bundle ID
    /// starts with the same group prefix probably shares it.
    static func sharedGroupContainer(_ name: String, owner: InstalledApp, others: [InstalledApp]) -> InstalledApp? {
        let parts = name.split(separator: ".", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let group = String(parts[1])
        return others.first { $0.bundleID != owner.bundleID && ($0.bundleID.hasPrefix(group) || group.hasPrefix($0.bundleID)) }
    }

    static func launchAgent(pointingInto bundle: URL, home: URL) -> String? {
        let dir = home.appendingPathComponent("Library/LaunchAgents")
        for plist in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        where plist.pathExtension == "plist" {
            guard let data = try? Data(contentsOf: plist),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            var paths: [String] = (dict["ProgramArguments"] as? [String]) ?? []
            if let p = dict["Program"] as? String { paths.append(p) }
            if paths.contains(where: { $0.hasPrefix(bundle.path + "/") }) { return plist.lastPathComponent }
        }
        return nil
    }

    public static func requests(for fp: AppFootprint, home: URL, layout: KhoLayout) -> [OffloadRequest] {
        let root = layout.relativePath(layout.appBundleRoot(bundleID: fp.app.bundleID))!
        var out = [OffloadRequest(original: fp.app.url, khoRelPath: "\(root)/bundle/\(fp.app.url.lastPathComponent)",
                                  purpose: .appBundle, leaveSymlink: false)]
        let homeCount = FileOps.components(home.path).count
        for folder in fp.folders {
            let rel = FileOps.components(folder.url.path).dropFirst(homeCount).joined(separator: "/")
            out.append(OffloadRequest(original: folder.url, khoRelPath: "\(root)/data/\(rel)",
                                      purpose: .appData, leaveSymlink: false))
        }
        return out
    }

    static func verifySignature(_ bundle: URL) async -> Int32 {
        (try? await CommandRunner.run(codesign, ["--verify", "--deep", "--strict", bundle.path], timeout: 600))?.exitCode ?? -1
    }

    public static func archive(
        _ fp: AppFootprint, service: OffloadService, ledger: Ledger, layout: KhoLayout,
        home: URL = FileManager.default.homeDirectoryForCurrentUser, otherApps: [InstalledApp] = [],
        isRunning: @escaping @Sendable (InstalledApp) -> Bool,
        progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> Int64 {
        let app = fp.app
        let e = eligibility(for: fp, isRunning: isRunning(app), ledger: ledger, home: home, otherApps: otherApps)
        guard e.allowed else { throw KhoError.invalidState(e.blockers.joined(separator: "; ")) }

        let before = await verifySignature(app.url)
        ledger.log(action: "codesign-before", path: app.url.path, detail: "exit \(before)", ok: before == 0)

        let check: @Sendable () throws -> Void = {
            if isRunning(app) { throw KhoError.appRunning(app.name) }
        }
        do {
            let opID = try service.offload(
                kind: .appCold, title: app.name, bundleID: app.bundleID,
                requests: requests(for: fp, home: home, layout: layout),
                preHoldCheck: check, afterEachHold: check, progress: progress, isCancelled: isCancelled)
            if let op = try ledger.operation(opID) {
                try ledger.setSetting("codesign.\(op.uid)", String(before))
            }
            return opID
        } catch KhoError.notPermitted(let what) where what == app.url.path {
            // Only known once the copy is done; the Kho copy has been removed again.
            throw KhoError.io(appManagementHint)
        }
    }

    public static let appManagementHint = "macOS chặn dời \"app\". Hãy cấp quyền cho Switch Kho ở Cài đặt hệ thống › Quyền riêng tư & Bảo mật › Quản lý ứng dụng, rồi thoát và mở lại Switch Kho."

    /// Undo while holding, pull back from the Kho once committed. Then re-registers the app
    /// with Launch Services and compares its signature with the check made before archiving.
    public static func restore(
        opID: Int64, service: OffloadService, ledger: Ledger,
        progress: @escaping @Sendable (CopyProgress) -> Void = { _ in },
        isCancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> AppRestoreResult {
        guard let op = try ledger.operation(opID), op.kind == .appCold else {
            throw KhoError.notFound("Thao tác #\(opID)")
        }
        // Refuse up front instead of bringing the app back beside a reinstalled copy: bundle in
        // one place and data in another would be worse than not restoring.
        if op.state == .holding || op.state == .committed {
            let occupied = service.occupiedOriginals(try ledger.items(opID))
            if !occupied.isEmpty {
                throw KhoError.destinationOccupied(occupied.joined(separator: "\n")
                    + "\nHãy xoá hoặc đổi tên bản đang nằm ở đó (ví dụ app vừa cài lại) rồi thử lại.")
            }
        }
        switch op.state {
        case .holding, .undoing: try service.undo(opID: opID, isCancelled: isCancelled)
        case .committed, .restoring: try service.restore(opID: opID, progress: progress, isCancelled: isCancelled)
        default: throw KhoError.invalidState("Thao tác không ở vùng chờ hay trên Kho")
        }
        let items = try ledger.items(opID)
        let relocated = items.compactMap { item in
            item.restoredPath.flatMap { $0 == item.originalPath ? nil : $0 }
        }
        guard let bundleItem = items.first(where: { $0.purpose == .appBundle }) else {
            return AppRestoreResult(signatureBroken: false, relocated: relocated)
        }
        // Check the bundle that actually came back, wherever it landed.
        let bundle = bundleItem.restoredPath.map(URL.init(fileURLWithPath:)) ?? bundleItem.originalURL
        LSRegisterURL(bundle as CFURL, true)
        let before = Int32((try? ledger.setting("codesign.\(op.uid)")) ?? nil ?? "") ?? -1
        let after = await verifySignature(bundle)
        let broken = before == 0 && after != 0
        ledger.log(action: "codesign-after", path: bundle.path, detail: "exit \(after)", ok: !broken)
        if broken {
            ledger.log(action: "Chữ ký app sau khi lấy về không hợp lệ — đừng mở app, hãy cài lại",
                       path: bundle.path, detail: nil, ok: false)
        }
        return AppRestoreResult(signatureBroken: broken, relocated: relocated)
    }
}
