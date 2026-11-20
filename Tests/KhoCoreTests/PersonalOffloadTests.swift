import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct PersonalOffloadTests {
    /// Folder with files last changed two days ago, so nothing counts as "in use".
    func oldFolder(_ fx: ServiceFixture, _ name: String) throws -> URL {
        let dir = fx.sb.home.appendingPathComponent("Downloads/\(name)")
        try fx.sb.makeFile(dir.appendingPathComponent("Báo cáo năm.pdf"), bytes: 5000, seed: 1)
        try fx.sb.makeFile(dir.appendingPathComponent("anh.jpg"), bytes: 5000, seed: 2)
        let now = Date()
        for u in [dir.appendingPathComponent("Báo cáo năm.pdf"), dir.appendingPathComponent("anh.jpg"), dir] {
            try fx.sb.setModified(u, daysAgo: 2, now: now)
        }
        return dir
    }

    func eventually(_ queue: JobQueue, _ check: () throws -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            _ = await queue.waitUntilIdle(timeout: .seconds(2))
            if try check() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    @Test func offloadAndUndoKeepTheCatalogInStep() async throws {
        let queue = JobQueue()
        let storeBox = Locked<CatalogStore?>(nil)
        let rootBox = Locked<URL?>(nil)
        let fx = try ServiceFixture(onKhoChanged: { added, removed in
            guard let store = storeBox.withLock({ $0 }) else { return }
            CatalogSync.makeHook(store: store, queue: queue, khoUUID: { ServiceFixture.khoUUID },
                                 khoRoot: { rootBox.withLock { $0 } })(added, removed)
        })
        defer { fx.cleanup() }
        let store = try CatalogStore(path: fx.sb.root.appendingPathComponent("db/catalog.sqlite"))
        storeBox.withLock { $0 = store }
        rootBox.withLock { $0 = fx.sb.layout.khoRoot }
        let dir = try oldFolder(fx, "old")
        let result = try PersonalOffload.offload([dir], title: "t", leaveSymlink: false, service: fx.service,
                                                 layout: fx.sb.layout)
        let opID = try #require(result.opID)
        #expect(result.skipped.isEmpty)
        #expect(try await eventually(queue) { try store.search("bao cao").count == 1 })
        let hit = try #require(try store.search("bao cao").first)
        #expect(hit.item.relPath == fx.rel(dir.appendingPathComponent("Báo cáo năm.pdf")))
        try PersonalOffload.bringBack(opID: opID, service: fx.service, ledger: fx.ledger)
        #expect(try await eventually(queue) { try store.search("bao cao").isEmpty })
        #expect(FileOps.exists(dir.appendingPathComponent("anh.jpg")))
    }

    @Test func openFileIsSkippedWithItsReason() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try oldFolder(fx, "a")
        let file = fx.sb.home.appendingPathComponent("Downloads/busy.bin")
        try fx.sb.makeFile(file, bytes: 100, seed: 3)
        try fx.sb.setModified(file, daysAgo: 2, now: Date())
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let result = try PersonalOffload.offload([dir, file], title: "t", leaveSymlink: false, service: fx.service,
                                                 layout: fx.sb.layout)
        #expect(result.opID != nil)
        #expect(result.skipped.map(\.url) == [file])
        #expect(result.skipped.first?.reason == InUseCheck.openElsewhere)
        #expect(FileOps.exists(file))
        #expect(!FileOps.exists(dir))
    }

    @Test func fileOpenedDuringCopyStopsTheMove() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let file = fx.sb.home.appendingPathComponent("Downloads/doc.bin")
        try fx.sb.makeFile(file, bytes: 5000, seed: 4)
        try fx.sb.setModified(file, daysAgo: 2, now: Date())
        let opened = Locked<FileHandle?>(nil)
        fx.afterCopy.withLock { $0 = { _ in opened.withLock { $0 = $0 ?? (try? FileHandle(forReadingFrom: file)) } } }
        defer { try? opened.withLock { $0 }?.close() }
        #expect(throws: KhoError.sourceChanged("doc.bin")) {
            _ = try PersonalOffload.offload([file], title: "t", leaveSymlink: false, service: fx.service,
                                            layout: fx.sb.layout)
        }
        #expect(try fx.ledger.operations().first?.state == .failed)
        #expect(FileOps.exists(file))
    }

    @Test func symlinkAndManagedItemsAreReported() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try oldFolder(fx, "m")
        _ = try PersonalOffload.offload([dir], title: "t", leaveSymlink: true, service: fx.service, layout: fx.sb.layout)
        // Now a symlink of ours sits there.
        let again = try PersonalOffload.offload([dir], title: "t", leaveSymlink: false, service: fx.service,
                                                layout: fx.sb.layout)
        #expect(again.opID == nil)
        #expect(again.skipped.count == 1)
    }

    @Test func bringBackRefusesAnOccupiedPlace() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try oldFolder(fx, "o")
        let opID = try #require(try PersonalOffload.offload([dir], title: "t", leaveSymlink: false,
                                                            service: fx.service, layout: fx.sb.layout).opID)
        try fx.sb.makeFile(dir.appendingPathComponent("moi.txt"), bytes: 10, seed: 5)
        #expect(throws: KhoError.self) {
            try PersonalOffload.bringBack(opID: opID, service: fx.service, ledger: fx.ledger)
        }
        #expect(try fx.ledger.operation(opID)?.state == .holding)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["moi.txt"])
    }
}
