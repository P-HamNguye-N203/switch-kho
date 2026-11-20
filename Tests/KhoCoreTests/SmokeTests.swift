import Testing
@testable import KhoCore

@Suite struct SmokeTests {
    @Test func version() {
        #expect(KhoCore.version == "0.1.0")
    }
}
