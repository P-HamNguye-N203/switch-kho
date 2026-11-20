import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct AcceptKhoCopyTests {
    @Test func editedThroughSymlinkCommitsOnlyAfterAccept() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let dir = try fx.makeFolder("A")
        let op = try fx.offload([fx.request(dir, symlink: true)])
        try Data("sửa qua liên kết".utf8).write(to: dir.appendingPathComponent("sub/f0.bin"))
        try Data("mới".utf8).write(to: dir.appendingPathComponent("moi.txt"))
        fx.advance(days: 8)
        #expect(fx.service.commitDue().isEmpty)
        #expect(try fx.ledger.operation(op)?.error != nil)

        try fx.service.acceptKhoCopy(opID: op)
        #expect(try fx.ledger.operation(op)?.error == nil)
        #expect(fx.service.commitDue() == [op])
        // Restore after commit now verifies against the accepted copy.
        try fx.service.restore(opID: op)
        #expect(try String(contentsOf: dir.appendingPathComponent("moi.txt"), encoding: .utf8) == "mới")
        #expect(try fx.ledger.operation(op)?.state == .restored)
    }

    @Test func acceptNeedsKhoAndRightState() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let op = try fx.offload([fx.request(try fx.makeFolder("A"))])
        fx.khoMounted.withLock { $0 = false }
        #expect(throws: KhoError.khoOffline) { try fx.service.acceptKhoCopy(opID: op) }
        fx.khoMounted.withLock { $0 = true }
        try fx.service.undo(opID: op)
        #expect(throws: KhoError.self) { try fx.service.acceptKhoCopy(opID: op) }
    }
}
