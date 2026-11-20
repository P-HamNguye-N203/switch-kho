import Foundation
import Testing
@testable import KhoCore

@Suite struct RunningProcessesTests {
    @Test func detectsFakeApp() throws {
        let sb = try TestSandbox()
        defer { sb.cleanup() }
        let app = try sb.makeRunnableFakeApp(name: "Fake", bundleID: "test.fake")
        let p = try sb.launch(app.appendingPathComponent("Contents/MacOS/Fake"))
        defer { if p.isRunning { p.terminate() } }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(RunningProcesses.isRunning(appURL: app))
        sb.stop(p)
        #expect(!RunningProcesses.isRunning(appURL: app))
    }
}
