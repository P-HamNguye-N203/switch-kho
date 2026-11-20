import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite struct DirectoryScannerTests {
    @Test func sizesHardLinksSymlinksAndOtherDevices() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let root = sb.home.appendingPathComponent("Documents/scan")
        try sb.makeFile(root.appendingPathComponent("a/b/c/f1"), bytes: 100_000, seed: 1)
        try sb.makeFile(root.appendingPathComponent("a/f2"), bytes: 200_000, seed: 2)
        #expect(link(root.appendingPathComponent("a/f2").path, root.appendingPathComponent("a/b/f2-link").path) == 0)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("toKho"), withDestinationURL: sb.kho)
        try sb.makeFile(sb.kho.appendingPathComponent("big"), bytes: 500_000, seed: 3)
        try sb.makeFile(root.appendingPathComponent("mount/x"), bytes: 300_000, seed: 4)

        let expected = AppDataMapper.stats(root.appendingPathComponent("a/b/c/f1")).allocated
            + AppDataMapper.stats(root.appendingPathComponent("a/f2")).allocated
        let scanner = DirectoryScanner(ignored: [], skip: { $0.lastPathComponent == "mount" })
        let result = try scanner.scan(root)
        #expect(result.root.size == expected)
        #expect(result.totalFiles == 2)
        #expect(!result.root.children.contains { $0.name == "mount" })
    }
}
