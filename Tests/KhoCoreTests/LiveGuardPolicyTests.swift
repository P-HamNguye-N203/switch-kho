import Testing
@testable import KhoCore

@Suite struct LiveGuardPolicyTests {
    let live: Set<String> = ["a", "b"]
    func d(_ e: GuardEvent, _ mounted: Bool) -> GuardAction {
        LiveGuardPolicy.decide(e, liveBundleIDs: live, khoMounted: mounted)
    }

    @Test func launchWithoutKhoStopsOnlyLiveApps() {
        #expect(d(.appLaunched(bundleID: "a"), false) == .terminate(["a"], reason: "Kho chưa cắm"))
        #expect(d(.appLaunched(bundleID: "z"), false) == .none)
    }
    @Test func launchWithKhoIsFine() { #expect(d(.appLaunched(bundleID: "a"), true) == .none) }
    @Test func willUnmountStopsAll() {
        #expect(d(.khoWillUnmount, true) == .terminate(["a", "b"], reason: "Kho bị tháo"))
        #expect(d(.khoWillUnmount, false) == .terminate(["a", "b"], reason: "Kho bị tháo"))
    }
    @Test func didUnmountStopsAll() {
        #expect(d(.khoDidUnmount, false) == .terminate(["a", "b"], reason: "Kho đã bị ngắt"))
        #expect(d(.khoDidUnmount, true) == .terminate(["a", "b"], reason: "Kho đã bị ngắt"))
    }
    @Test func mountChecks() {
        #expect(d(.khoDidMount, true) == .checkIntegrity)
        #expect(d(.khoDidMount, false) == .checkIntegrity)
    }
    @Test func wakeDependsOnKho() {
        #expect(d(.didWake, true) == .checkIntegrity)
        #expect(d(.didWake, false) == .terminate(["a", "b"], reason: "Kho chưa cắm"))
    }
    @Test func tickOnlyActsWithoutKho() {
        #expect(d(.tick, false) == .terminate(["a", "b"], reason: "Kho chưa cắm"))
        #expect(d(.tick, true) == .none)
    }
    @Test func startStopsRunningLiveAppsWithoutKho() {
        #expect(d(.guardStarted(runningBundleIDs: ["b", "z"]), false) == .terminate(["b"], reason: "Kho chưa cắm"))
        #expect(d(.guardStarted(runningBundleIDs: ["z"]), false) == .none)
        #expect(d(.guardStarted(runningBundleIDs: ["b"]), true) == .checkIntegrity)
    }
    @Test func nothingLiveMeansNothingToStop() {
        #expect(LiveGuardPolicy.decide(.tick, liveBundleIDs: [], khoMounted: false) == .none)
        #expect(LiveGuardPolicy.decide(.khoDidUnmount, liveBundleIDs: [], khoMounted: false) == .none)
    }
    @Test func everyEventIsDecided() {
        for mounted in [true, false] {
            for e: GuardEvent in [.appLaunched(bundleID: "a"), .khoWillUnmount, .khoDidUnmount, .khoDidMount,
                                  .didWake, .tick, .guardStarted(runningBundleIDs: ["a"])] {
                _ = d(e, mounted)
            }
        }
    }
}
