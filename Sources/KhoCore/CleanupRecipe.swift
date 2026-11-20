import Foundation

public enum CleanupDeletion: Sendable, Equatable {
    case permanent, trash
}

public enum CleanupMethod: Sendable, Equatable {
    case paths([URL], CleanupDeletion)
    case command(executable: URL, args: [String], previewArgs: [String]?)
}

public enum AppStateRequirement: Sendable, Equatable {
    case none
    case mustBeQuit(appURL: URL)
    case mustBeRunning(appURL: URL)
    /// A tool check that must exit 0, e.g. `docker info` (works for Docker Desktop, OrbStack, Colima).
    case commandSucceeds(executable: URL, args: [String], hint: String)
}

/// One group of regenerable or disposable data the user can clean.
public struct CleanupCandidate: Sendable, Identifiable, Equatable {
    public let id: String
    public let title: String
    public let detail: String
    public let method: CleanupMethod
    public let requirement: AppStateRequirement
    public let estimatedBytes: Int64
    public let warning: String?
    /// Unknown owner: never part of "clean all selected", only cleaned one by one.
    public let manualOnly: Bool

    public init(id: String, title: String, detail: String, method: CleanupMethod,
                requirement: AppStateRequirement, estimatedBytes: Int64, warning: String? = nil,
                manualOnly: Bool = false) {
        self.id = id
        self.title = title
        self.detail = detail
        self.method = method
        self.requirement = requirement
        self.estimatedBytes = estimatedBytes
        self.warning = warning
        self.manualOnly = manualOnly
    }

    public var paths: [URL] {
        if case .paths(let urls, _) = method { return urls }
        return []
    }
}
