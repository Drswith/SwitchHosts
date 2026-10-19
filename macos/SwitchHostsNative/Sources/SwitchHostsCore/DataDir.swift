import Foundation

/// Where the data lives and whether it can be changed, as the core reports it.
public struct DataDirStatus: Decodable, Equatable, Sendable {
    public let activeDir: String
    public let defaultDir: String
    public let canReset: Bool
    /// Set when the recorded folder was unusable at launch: "missing" or "invalid".
    public let recoveryKind: String?
    /// The folder that went missing. Nil for an unreadable pointer.
    public let recoveryPath: String?

    enum CodingKeys: String, CodingKey {
        case activeDir = "active_dir"
        case defaultDir = "default_dir"
        case canReset = "can_reset"
        case recovery
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeDir = try container.decode(String.self, forKey: .activeDir)
        defaultDir = try container.decode(String.self, forKey: .defaultDir)
        canReset = try container.decode(Bool.self, forKey: .canReset)
        let recovery = try container.decodeIfPresent(Recovery.self, forKey: .recovery)
        recoveryKind = recovery?.kind
        recoveryPath = recovery?.path
    }

    /// `path` is null for an unreadable pointer, so it is optional here.
    private struct Recovery: Decodable {
        let kind: String
        let path: String?
    }
}

/// What a folder the user picked would become: the default location or a custom folder.
public struct DataDirPlan: Decodable, Equatable, Sendable {
    public let kind: String
    public let dataDir: String
    public let isEmpty: Bool
    public let isSameAsCurrent: Bool

    enum CodingKeys: String, CodingKey {
        case kind
        case dataDir = "data_dir"
        case isEmpty = "is_empty"
        case isSameAsCurrent = "is_same_as_current"
    }

    public var isDefault: Bool { kind == "default" }
}
