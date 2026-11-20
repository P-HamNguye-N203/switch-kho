import Foundation
import Synchronization
@testable import KhoCore

/// A shareable reference to a `Mutex`, so `@Sendable` closures can capture it.
final class Locked<T: Sendable>: Sendable {
    private let m: Mutex<T>
    init(_ value: T) { m = Mutex(value) }
    func withLock<R>(_ body: (inout T) -> R) -> R { m.withLock { body(&$0) } }
}

/// An OffloadService wired to a sandbox, with switchable clock, Kho presence, running app
/// and copy corruption.
final class ServiceFixture: Sendable {
    let sb: TestSandbox
    let ledger: Ledger
    let service: OffloadService
    let clock = Locked(Date(timeIntervalSince1970: 1_900_000_000))
    let holdError = Locked<KhoError>(.io("hook: hold failed"))
    let khoMounted = Locked(true)
    let running = Locked(false)
    /// File names whose copy gets one byte flipped after copyfile.
    let corrupt = Locked<Set<String>>([])
    /// Called after each file copy (for source-change tests).
    let afterCopy = Locked<(@Sendable (URL) -> Void)?>(nil)
    let failHoldFor = Locked<String?>(nil)
    static let khoUUID = "KHO-UUID-1"

    var kho: MountedKho { MountedKho(uuid: Self.khoUUID, layout: sb.layout) }

    init() throws {
        sb = try TestSandbox()
        ledger = try Ledger(path: sb.dbPath)
        let corrupt = self.corrupt
        let afterCopy = self.afterCopy
        let copier = VerifiedCopier(capacityProvider: { _ in Int64(1) << 40 }, afterFileCopied: { url in
            if corrupt.withLock({ $0.contains(url.lastPathComponent) }),
               let h = try? FileHandle(forWritingTo: url)
            {
                try? h.seek(toOffset: 0)
                h.write(Data([0xEE]))
                try? h.close()
            }
            afterCopy.withLock { $0 }?(url)
        })
        let failHoldFor = self.failHoldFor, holdError = self.holdError
        let holding = HoldingArea(
            root: sb.home.appendingPathComponent("Library/Application Support/SwitchKho/Holding"),
            beforeRename: { url in
                if failHoldFor.withLock({ $0 }) == url.lastPathComponent { throw holdError.withLock { $0 } }
            })
        let clock = self.clock, mounted = self.khoMounted, running = self.running
        let kho = MountedKho(uuid: Self.khoUUID, layout: sb.layout)
        service = OffloadService(
            ledger: ledger, holding: holding, policy: sb.policy, copier: copier,
            mountedKho: { mounted.withLock { $0 } ? kho : nil },
            holdDays: { 7 }, now: { clock.withLock { $0 } },
            appRunning: { _ in running.withLock { $0 } })
    }

    func cleanup() { sb.cleanup() }

    func advance(days: Double) { clock.withLock { $0 = $0.addingTimeInterval(days * 86_400) } }

    func rel(_ original: URL) -> String { sb.layout.relativePath(sb.layout.archiveURL(forOriginal: original))! }

    func request(_ original: URL, symlink: Bool = false, purpose: PathPurpose = .personal) -> OffloadRequest {
        OffloadRequest(original: original, khoRelPath: rel(original), purpose: purpose, leaveSymlink: symlink)
    }

    @discardableResult
    func offload(_ requests: [OffloadRequest], kind: OperationKind = .personal, bundleID: String? = nil) throws -> Int64 {
        try service.offload(kind: kind, title: "t", bundleID: bundleID, requests: requests,
                            progress: { _ in }, isCancelled: { false })
    }

    /// A folder with a few files under ~/Documents.
    func makeFolder(_ name: String, files: Int = 3) throws -> URL {
        let dir = sb.home.appendingPathComponent("Documents/\(name)")
        for i in 0..<files {
            try sb.makeFile(dir.appendingPathComponent("sub/f\(i).bin"), bytes: 4000 + i, seed: UInt8(i))
        }
        return dir
    }

    func digest(_ dir: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)!
        for case let u as URL in walker where !FileOps.isSymlink(u) {
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir)
            if !isDir.boolValue {
                out[String(u.path.dropFirst(dir.path.count))] = try ContentDigest.segmentsAndDigest(u).digest
            }
        }
        return out
    }

    func khoCopy(_ op: Int64) throws -> URL {
        let item = try ledger.items(op)[0]
        return try sb.layout.absoluteURL(relative: item.khoRelPath!)
    }

    func archiveEntries() -> [String] {
        let walker = FileManager.default.enumerator(atPath: sb.layout.archive.path)
        return (walker?.allObjects as? [String]) ?? []
    }
}
