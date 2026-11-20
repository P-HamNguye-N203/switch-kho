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
        } catch KhoError.notDeletable(let what) where what == app.url.path {
            throw KhoError.io("Cần cấp quyền App Management cho Switch Kho: Cài đặt hệ thống › Quyền riêng tư & Bảo mật › Quản lý ứng dụng")
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain
            && (error.code == Int(EPERM) || error.code == Int(EACCES)) {
            throw KhoError.io("Cần cấp quyền App Management cho Switch Kho: Cài đặt hệ thống › Quyền riêng tư & Bảo mật › Quản lý ứng dụng")
        }
    }

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
        switch op.state {
        case .holding, .undoing: try service.undo(opID: opID, isCancelled: isCancelled)
        case .committed, .restoring: try service.restore(opID: opID, progress: progress, isCancelled: isCancelled)
        default: throw KhoError.invalidState("Thao tác không ở vùng chờ hay trên Kho")
        }
        guard let bundle = try ledger.items(opID).first(where: { $0.purpose == .appBundle })?.originalURL else {
            return AppRestoreResult(signatureBroken: false)
        }
        LSRegisterURL(bundle as CFURL, true)
        let before = Int32((try? ledger.setting("codesign.\(op.uid)")) ?? nil ?? "") ?? -1
        let after = await verifySignature(bundle)
        let broken = before == 0 && after != 0
        ledger.log(action: "codesign-after", path: bundle.path, detail: "exit \(after)", ok: !broken)
        if broken {
            ledger.log(action: "Chữ ký app sau khi lấy về không hợp lệ — đừng mở app, hãy cài lại",
                       path: bundle.path, detail: nil, ok: false)
        }
        return AppRestoreResult(signatureBroken: broken)
    }
}
