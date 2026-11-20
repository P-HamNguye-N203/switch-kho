import Foundation

public enum GuardEvent: Sendable {
    case appLaunched(bundleID: String)
    case khoWillUnmount
    case khoDidUnmount
    case khoDidMount
    case didWake
    /// Every 5 seconds, only while the Kho is away.
    case tick
    case guardStarted(runningBundleIDs: [String])
}

public enum GuardAction: Sendable, Equatable {
    /// Bundle IDs to stop; the caller only acts on the ones actually running.
    case terminate([String], reason: String)
    case checkIntegrity
    case none
}

/// What the guard does for each event, free of AppKit so it can be tested.
public enum LiveGuardPolicy {
    public static let noKho = "Kho chưa cắm"

    public static func decide(_ e: GuardEvent, liveBundleIDs: Set<String>, khoMounted: Bool) -> GuardAction {
        let all = liveBundleIDs.sorted()
        func stop(_ ids: [String], _ reason: String) -> GuardAction { ids.isEmpty ? .none : .terminate(ids, reason: reason) }
        switch e {
        case .appLaunched(let b):
            return liveBundleIDs.contains(b) && !khoMounted ? .terminate([b], reason: noKho) : .none
        case .khoWillUnmount:
            return stop(all, "Kho bị tháo")
        case .khoDidUnmount:
            // Pulling the cable sends no "will unmount".
            return stop(all, "Kho đã bị ngắt")
        case .khoDidMount:
            return .checkIntegrity
        case .didWake:
            return khoMounted ? .checkIntegrity : stop(all, noKho)
        case .tick:
            return khoMounted ? .none : stop(all, noKho)
        case .guardStarted(let running):
            return khoMounted ? .checkIntegrity : stop(running.filter(liveBundleIDs.contains).sorted(), noKho)
        }
    }
}
