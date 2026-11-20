import Foundation
import Testing
@testable import KhoCore

@Suite struct KhoLinkTests {
    @Test func updateCreatesAndRemovesLink() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let link = sb.root.appendingPathComponent("support/KhoLink")
        try sb.makeFile(sb.layout.archive.appendingPathComponent("a/x.txt"), bytes: 5, seed: 1)
        let kho = MountedKho(uuid: "U", layout: KhoLayout(khoRoot: sb.kho, linkRoot: link))
        try KhoLink.update(linkRoot: link, kho: kho)
        try KhoLink.update(linkRoot: link, kho: kho)
        #expect(FileManager.default.fileExists(atPath: link.appendingPathComponent("Archive/a/x.txt").path))
        try KhoLink.update(linkRoot: link, kho: nil)
        #expect(!FileOps.exists(link))

        try FileManager.default.createDirectory(at: link, withIntermediateDirectories: true)
        #expect(throws: KhoError.self) { try KhoLink.update(linkRoot: link, kho: nil) }
        #expect(FileOps.exists(link))
    }
}
