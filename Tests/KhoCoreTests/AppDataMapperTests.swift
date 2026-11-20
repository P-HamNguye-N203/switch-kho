import Darwin
import Foundation
import Testing
@testable import KhoCore

@Suite(.serialized) struct AppDataMapperTests {
    func fakeApp(_ sb: TestSandbox, _ name: String, _ id: String) throws -> InstalledApp {
        let url = sb.applications.appendingPathComponent("\(name).app")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        return try #require(AppCatalog.read(url))
    }

    @Test func mapsFoldersToApps() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let alpha = try fakeApp(sb, "Alpha", "test.alpha")
        let beta = try fakeApp(sb, "Beta", "test.beta")
        let vm = try fakeApp(sb, "VMApp", "test.vm")
        #expect(AppCatalog.scan(dirs: [sb.applications]).count == 3)
        let lib = sb.home.appendingPathComponent("Library")
        try sb.makeFile(lib.appendingPathComponent("Containers/test.alpha/a"), bytes: 4096, seed: 1)
        try sb.makeFile(lib.appendingPathComponent("Application Support/Beta/b"), bytes: 4096, seed: 2)
        try sb.makeFile(lib.appendingPathComponent("Application Support/Hinted/h"), bytes: 4096, seed: 3)
        try sb.makeFile(lib.appendingPathComponent("Application Support/Orphan/o"), bytes: 4096, seed: 4)
        try sb.makeFile(lib.appendingPathComponent("Application Support/SwitchKho/Holding/x"), bytes: 4096, seed: 5)
        let disk = lib.appendingPathComponent("Containers/test.vm/disk.raw")
        try FileManager.default.createDirectory(at: disk.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(disk.path, O_RDWR | O_CREAT, 0o644)
        ftruncate(fd, off_t(2) << 30)
        close(fd)

        var map = AppDataMapper.map(home: sb.home, apps: [alpha, beta, vm], overrides: [:],
                                    extraHints: ["test.beta": ["Hinted"]])
        func folders(_ id: String) -> [String] {
            map.footprints.first { $0.app.bundleID == id }!.folders.map(\.url.lastPathComponent).sorted()
        }
        #expect(folders("test.alpha") == ["test.alpha"])
        #expect(folders("test.beta") == ["Beta", "Hinted"])
        #expect(map.footprints.first { $0.app.bundleID == "test.vm" }!.hasVMImage)
        #expect(map.unassigned.map(\.url.lastPathComponent) == ["Orphan"])

        let orphan = lib.appendingPathComponent("Application Support/Orphan").path
        map = AppDataMapper.map(home: sb.home, apps: [alpha, beta, vm], overrides: [orphan: "test.alpha"])
        #expect(folders("test.alpha") == ["Orphan", "test.alpha"])
        #expect(map.unassigned.isEmpty || !map.unassigned.contains { $0.url.lastPathComponent == "Orphan" })
    }
}
