import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct RuleEngineTests {
    /// Sets the "last opened" date Finder writes.
    static func setLastUsed(_ url: URL, _ date: Date) {
        var buf = [UInt8](repeating: 0, count: 16)
        let sec = Int64(date.timeIntervalSince1970)
        for i in 0..<8 { buf[i] = UInt8(truncatingIfNeeded: sec >> (8 * Int64(i))) }
        _ = setxattr(url.path, "com.apple.lastuseddate#PS", buf, 16, 0, 0)
    }

    /// Without the "date added" every test file carries (today).
    static func usage(_ url: URL) -> UsageDate? {
        if let d = FileUsage.lastUsedXattr(url) { return UsageDate(date: d, source: .lastUsedXattr) }
        return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { UsageDate(date: $0, source: .modified) }
    }

    func rule(_ folder: URL, exts: [String] = ["dmg"], mode: RuleMode = .suggest) -> OffloadRule {
        OffloadRule(name: "Bộ cài cũ", folderPath: folder.path, minDaysUnused: 90, minSizeMB: 1, extensions: exts,
                    mode: mode, leaveSymlink: false, enabled: true)
    }

    func setUp(_ sb: TestSandbox, now: Date) throws -> URL {
        let dl = sb.home.appendingPathComponent("Downloads")
        let a = dl.appendingPathComponent("a.dmg"), b = dl.appendingPathComponent("b.dmg"), c = dl.appendingPathComponent("c.txt")
        for (u, s) in [(a, 1), (b, 2), (c, 3)] { try sb.makeFile(u, bytes: 2 << 20, seed: UInt8(s)) }
        try sb.setModified(a, daysAgo: 200, now: now)
        Self.setLastUsed(a, now.addingTimeInterval(-120 * 86_400))
        try sb.setModified(c, daysAgo: 200, now: now)
        let d = dl.appendingPathComponent("d")
        try sb.makeFile(d.appendingPathComponent("x.dmg"), bytes: 2 << 20, seed: 4)
        try sb.setModified(d.appendingPathComponent("x.dmg"), daysAgo: 5, now: now)
        try sb.setModified(d, daysAgo: 200, now: now)
        return dl
    }

    @Test func picksOnlyOldBigMatchingItems() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let now = Date()
        let dl = try setUp(sb, now: now)
        let ledger = try Ledger(path: sb.dbPath)
        let found = RuleEngine.candidates(for: rule(dl), ledger: ledger, policy: sb.policy, now: now, usageDate: Self.usage)
        #expect(found.map(\.url.lastPathComponent) == ["a.dmg"])
        #expect(found.first?.usage.source == .lastUsedXattr)
        // Any extension: the folder whose child was used 5 days ago still stays.
        let any = RuleEngine.candidates(for: rule(dl, exts: []), ledger: ledger, policy: sb.policy, now: now,
                                        usageDate: Self.usage)
        #expect(Set(any.map(\.url.lastPathComponent)) == ["a.dmg", "c.txt"])
    }

    @Test func rulesRoundTripThroughSettings() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let ledger = try Ledger(path: sb.dbPath)
        let r = rule(sb.home)
        try r.save(ledger)
        #expect(try OffloadRule.all(ledger) == [r])
        try r.delete(ledger)
        #expect(try OffloadRule.all(ledger).isEmpty)
    }

    @Test func autoRunsOnlyWithTheKho() throws {
        let fx = try ServiceFixture()
        defer { fx.cleanup() }
        let now = Date()
        let dl = try setUp(fx.sb, now: now)
        let auto = rule(dl, mode: .auto)
        #expect(RuleEngine.runAuto(rules: [auto], khoMounted: false, service: fx.service, ledger: fx.ledger,
                                   policy: fx.sb.policy, layout: fx.sb.layout, now: now, usageDate: Self.usage).isEmpty)
        #expect(try fx.ledger.operationCount() == 0)
        let out = RuleEngine.runAuto(rules: [auto, rule(dl, mode: .suggest)], khoMounted: true, service: fx.service,
                                     ledger: fx.ledger, policy: fx.sb.policy, layout: fx.sb.layout, now: now,
                                     usageDate: Self.usage)
        #expect(out.count == 1)
        let op = try #require(try fx.ledger.operations().first)
        #expect(op.title == "Quy tắc: Bộ cài cũ")
        #expect(op.state == .holding)
        #expect(!FileOps.exists(dl.appendingPathComponent("a.dmg")))
        #expect(FileOps.exists(dl.appendingPathComponent("b.dmg")))
    }
}
