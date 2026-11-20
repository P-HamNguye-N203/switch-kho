import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct InUseCheckTests {
    @Test func recentOpenAndIdleFiles() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let now = Date()
        let fresh = sb.home.appendingPathComponent("Downloads/fresh.bin")
        try sb.makeFile(fresh, bytes: 100, seed: 1)
        #expect(InUseCheck.reason(fresh, now: now) == InUseCheck.recentlyChanged)

        let open = sb.home.appendingPathComponent("Downloads/open.bin")
        try sb.makeFile(open, bytes: 100, seed: 2)
        try sb.setModified(open, daysAgo: 1, now: now)
        let handle = try FileHandle(forReadingFrom: open)
        defer { try? handle.close() }
        #expect(InUseCheck.reason(open, now: now) == InUseCheck.openElsewhere)

        let idle = sb.home.appendingPathComponent("Downloads/idle.bin")
        try sb.makeFile(idle, bytes: 100, seed: 3)
        try sb.setModified(idle, daysAgo: 1, now: now)
        #expect(InUseCheck.reason(idle, now: now) == nil)
    }

    @Test func hungOrMissingToolCountsAsUnknown() throws {
        let file = URL(fileURLWithPath: "/etc/hosts")
        let start = Date()
        #expect(InUseCheck.openCheck(file, tool: URL(fileURLWithPath: "/bin/sleep"), arguments: ["30"], timeout: 1) == .unknown)
        #expect(Date().timeIntervalSince(start) < 3)
        #expect(InUseCheck.openCheck(file, tool: URL(fileURLWithPath: "/nonexistent/lsof")) == .unknown)
        #expect(InUseCheck.openCheck(file, tool: URL(fileURLWithPath: "/usr/bin/true"), arguments: []) == .closed)
        #expect(InUseCheck.openCheck(file, tool: URL(fileURLWithPath: "/bin/echo"), arguments: ["123"]) == .open)
    }

    @Test func folderCountsItsNewestChild() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let now = Date()
        let dir = sb.home.appendingPathComponent("Documents/p")
        try sb.makeFile(dir.appendingPathComponent("old.txt"), bytes: 10, seed: 1)
        try sb.makeFile(dir.appendingPathComponent("sub/new.txt"), bytes: 10, seed: 2)
        for u in [dir, dir.appendingPathComponent("old.txt"), dir.appendingPathComponent("sub")] {
            try sb.setModified(u, daysAgo: 3, now: now)
        }
        #expect(InUseCheck.reason(dir, now: now) == InUseCheck.recentlyChanged)
        try sb.setModified(dir.appendingPathComponent("sub/new.txt"), daysAgo: 3, now: now)
        #expect(InUseCheck.reason(dir, now: now) == nil)
    }
}
