import Foundation

public enum RuleMode: String, Codable, Sendable { case suggest, auto }

/// "Offload items in this folder unused for N days": suggested, or done automatically.
public struct OffloadRule: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var folderPath: String
    public var minDaysUnused: Int
    public var minSizeMB: Int
    /// Lowercased, without dots; empty means every extension.
    public var extensions: [String]
    public var mode: RuleMode
    public var leaveSymlink: Bool
    public var enabled: Bool

    public init(id: UUID = UUID(), name: String, folderPath: String, minDaysUnused: Int, minSizeMB: Int,
                extensions: [String], mode: RuleMode, leaveSymlink: Bool, enabled: Bool) {
        self.id = id
        self.name = name
        self.folderPath = folderPath
        self.minDaysUnused = minDaysUnused
        self.minSizeMB = minSizeMB
        self.extensions = extensions
        self.mode = mode
        self.leaveSymlink = leaveSymlink
        self.enabled = enabled
    }

    static let prefix = "rule."
    var settingKey: String { Self.prefix + id.uuidString }

    /// Stored as JSON in the ledger's settings; no table of its own.
    public static func all(_ ledger: Ledger) throws -> [OffloadRule] {
        try ledger.settings(withPrefix: prefix).values.compactMap {
            try? JSONDecoder().decode(OffloadRule.self, from: Data($0.utf8))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func save(_ ledger: Ledger) throws {
        try ledger.setSetting(settingKey, String(decoding: try JSONEncoder().encode(self), as: UTF8.self))
    }

    public func delete(_ ledger: Ledger) throws { try ledger.removeSetting(settingKey) }
}
