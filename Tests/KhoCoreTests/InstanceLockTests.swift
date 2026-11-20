import Foundation
import Testing
@testable import KhoCore

@Suite struct InstanceLockTests {
    @Test func secondAcquireFailsUntilReleased() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let url = sb.root.appendingPathComponent("support/.lock")
        var first = InstanceLock.acquire(at: url)
        #expect(first != nil)
        #expect(InstanceLock.acquire(at: url) == nil)
        first = nil
        #expect(InstanceLock.acquire(at: url) != nil)
    }
}
