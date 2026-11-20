import Darwin
import Foundation
import Testing
@testable import KhoCore

/// A throwaway directory tree shaped like the real machine. Every test works inside it.
struct TestSandbox {
    let root: URL

    var home: URL { root.appendingPathComponent("home") }
    var applications: URL { root.appendingPathComponent("Applications") }
    var kho: URL { root.appendingPathComponent("kho") }
    var holding: URL { root.appendingPathComponent("holding") }
    var dbPath: URL { root.appendingPathComponent("db/test.sqlite") }
    var khoLink: URL { root.appendingPathComponent("link/KhoLink") }
    var layout: KhoLayout { KhoLayout(khoRoot: kho, linkRoot: khoLink) }

    init() throws {
        let raw = FileManager.default.temporaryDirectory
            .appendingPathComponent("switchkho-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        guard let real = FileOps.realpath(raw.path) else { throw KhoError.io("realpath failed") }
        root = URL(fileURLWithPath: real)
        let dirs = [
            "home", "home/Library/Application Support", "home/Library/Containers",
            "home/Library/Caches", "home/Downloads", "home/Documents", "home/.Trash",
            "home/.npm/_cacache", "home/.cache/pip", "Applications", "kho/SwitchKho",
            "holding", "db", "link",
        ]
        for d in dirs {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(d), withIntermediateDirectories: true)
        }
        try FileManager.default.createSymbolicLink(
            at: khoLink, withDestinationURL: kho.appendingPathComponent("SwitchKho"))
    }

    var policy: PathPolicy {
        PathPolicy(
            home: home, applicationsDirs: [applications],
            protectedRoots: [URL(fileURLWithPath: "/System"), URL(fileURLWithPath: "/Volumes")],
            selfAppURL: nil)
    }

    /// Writes `bytes` deterministic bytes derived from `seed`.
    func makeFile(_ path: URL, bytes: Int, seed: UInt8) throws {
        try FileManager.default.createDirectory(
            at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        var bytesArray = [UInt8](repeating: 0, count: bytes)
        for i in 0..<bytes { bytesArray[i] = UInt8(truncatingIfNeeded: i &* 31 &+ Int(seed)) }
        try Data(bytesArray).write(to: path)
    }

    /// A real, launchable app bundle whose executable is compiled with clang.
    /// Copying an Apple binary such as /bin/sleep gets it killed by macOS (exit 137).
    func makeRunnableFakeApp(name: String, bundleID: String) throws -> URL {
        let app = applications.appendingPathComponent("\(name).app")
        let macOS = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID, "CFBundleName": name, "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))

        let clang = Process()
        clang.executableURL = URL(fileURLWithPath: "/usr/bin/clang")
        clang.arguments = ["-x", "c", "-", "-o", macOS.appendingPathComponent(name).path]
        let input = Pipe()
        clang.standardInput = input
        try clang.run()
        input.fileHandleForWriting.write(Data("#include <unistd.h>\nint main(void){sleep(60);return 0;}\n".utf8))
        try input.fileHandleForWriting.close()
        clang.waitUntilExit()
        guard clang.terminationStatus == 0 else { throw KhoError.io("clang failed") }
        return app
    }

    func launch(_ executable: URL) throws -> Process {
        let p = Process()
        p.executableURL = executable
        try p.run()
        return p
    }

    /// Stops a launched process. Never `waitUntilExit()` after an `await`: Foundation can miss
    /// the exit when the waiting thread is not the one that called `run()`, and hang forever.
    func stop(_ p: Process?) {
        guard let p else { return }
        if p.isRunning { p.terminate() }
        let deadline = Date().addingTimeInterval(10)
        while p.isRunning && Date() < deadline { usleep(10_000) }
        if p.isRunning {
            kill(p.processIdentifier, SIGKILL)
            usleep(200_000)
            if p.isRunning { Issue.record("Tiến trình \(p.processIdentifier) không dừng") }
        }
    }

    func cleanup() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/chflags")
        p.arguments = ["-R", "nouchg", root.path]
        try? p.run()
        p.waitUntilExit()
        try? FileManager.default.removeItem(at: root)
    }
}
