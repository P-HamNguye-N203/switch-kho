import Foundation
import Testing
@testable import KhoCore

@Suite struct PathPolicyTests {
    struct Case: Sendable, CustomStringConvertible {
        let path: String
        let purpose: PathPurpose
        let allowed: Bool
        var description: String { "\(allowed ? "allow" : "block") \(purpose) \(path)" }
    }

    /// Paths are relative to the sandbox root; "@VAR" swaps the root for its /var spelling.
    static let cases: [Case] = [
        Case(path: "home/Downloads/a.dmg", purpose: .personal, allowed: true),
        Case(path: "home/Library/Containers/com.x", purpose: .appData, allowed: true),
        Case(path: "Applications/X.app", purpose: .appBundle, allowed: true),
        Case(path: "home/.Trash/x", purpose: .trashContents, allowed: true),
        Case(path: "home/.npm/_cacache/content-v2", purpose: .packageCache, allowed: true),
        Case(path: "@VAR/home/Downloads/a.dmg", purpose: .personal, allowed: true),
        Case(path: "home", purpose: .personal, allowed: false),
        Case(path: "home/Library", purpose: .appData, allowed: false),
        Case(path: "home/Library/Caches", purpose: .appData, allowed: false),
        Case(path: "home/Library/Preferences/x.plist", purpose: .appData, allowed: false),
        Case(path: "home/Library/Application Support/SwitchKho/x", purpose: .appData, allowed: false),
        Case(path: "home/Library/Containers/com.x", purpose: .personal, allowed: false),
        Case(path: "/System/x", purpose: .personal, allowed: false),
        Case(path: "/Volumes/Kho/x", purpose: .personal, allowed: false),
        Case(path: "Applications/X.app/Contents", purpose: .appBundle, allowed: false),
        Case(path: "Applications/Sub/X.app", purpose: .appBundle, allowed: false),
        Case(path: "home/.Trash/x", purpose: .personal, allowed: false),
        Case(path: "home/.Trash/a/b", purpose: .trashContents, allowed: false),
        Case(path: "home/library/Preferences/x", purpose: .personal, allowed: false),
        Case(path: "home/Downloads/lib/Keychains", purpose: .personal, allowed: false),
        Case(path: "home/.ssh/id", purpose: .personal, allowed: false),
        Case(path: "home2/x", purpose: .personal, allowed: false),
        Case(path: "home/Downloads/../Library/x", purpose: .personal, allowed: false),
        Case(path: "home/.npm/_cacache", purpose: .packageCache, allowed: false),
        Case(path: "home/.ssh/x", purpose: .packageCache, allowed: false),
        Case(path: "home/.npm/_cacache/x", purpose: .personal, allowed: false),
        Case(path: "home/Pictures/Photos Library.photoslibrary", purpose: .personal, allowed: false),
    ]

    @Test func matrixIsLargeEnough() {
        #expect(Self.cases.count >= 25)
    }

    @Test func sandboxRootIsRealPath() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        #expect(sb.root.path.hasPrefix("/private/var/"))
    }

    @Test(arguments: cases)
    func matrix(_ c: Case) throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let fm = FileManager.default
        try fm.createDirectory(at: sb.root.appendingPathComponent("home2"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sb.home.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sb.home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sb.home.appendingPathComponent("Pictures"), withIntermediateDirectories: true)
        try fm.createDirectory(at: sb.applications.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: sb.home.appendingPathComponent("Downloads/lib"),
                                  withDestinationURL: sb.home.appendingPathComponent("Library"))

        let url: URL
        if c.path.hasPrefix("/") {
            url = URL(fileURLWithPath: c.path)
        } else if c.path.hasPrefix("@VAR/") {
            let varRoot = String(sb.root.path.dropFirst("/private".count))
            url = URL(fileURLWithPath: varRoot + "/" + c.path.dropFirst("@VAR/".count))
        } else {
            url = URL(fileURLWithPath: sb.root.path + "/" + c.path)
        }
        #expect(sb.policy.isAllowed(url, purpose: c.purpose) == c.allowed, "\(c)")
    }
}
