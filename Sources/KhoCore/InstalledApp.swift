import Foundation

public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { url.path }
    public let url: URL
    public let bundleID: String
    public let name: String
    public let executableName: String
    public let isAppStore: Bool
    public let hasSparkle: Bool
    public let isElectron: Bool
    public let isAdobe: Bool
    public let ownerIsRoot: Bool
    public let lastUsed: UsageDate?

    public init(url: URL, bundleID: String, name: String, executableName: String, isAppStore: Bool = false,
                hasSparkle: Bool = false, isElectron: Bool = false, isAdobe: Bool = false,
                ownerIsRoot: Bool = false, lastUsed: UsageDate? = nil) {
        self.url = url
        self.bundleID = bundleID
        self.name = name
        self.executableName = executableName
        self.isAppStore = isAppStore
        self.hasSparkle = hasSparkle
        self.isElectron = isElectron
        self.isAdobe = isAdobe
        self.ownerIsRoot = ownerIsRoot
        self.lastUsed = lastUsed
    }
}
