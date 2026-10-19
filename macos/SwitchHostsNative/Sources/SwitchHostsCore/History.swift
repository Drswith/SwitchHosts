import Foundation

/// One saved state of the system hosts file, as the core stores it.
public struct ApplyRecord: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let content: String
    public let addTimeMs: Int64

    enum CodingKeys: String, CodingKey {
        case id, content
        case addTimeMs = "add_time_ms"
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(addTimeMs) / 1000) }
}

/// What lowering the history limit would delete. The core changes nothing
/// until the same numbers come back as a confirmation.
public struct HistoryLimitPreview: Equatable, Sendable {
    public let limit: Int
    public let previousLimit: Int
    public let deleteCount: Int
    public let retainedCount: Int

    public init(limit: Int, previousLimit: Int, deleteCount: Int, retainedCount: Int) {
        self.limit = limit
        self.previousLimit = previousLimit
        self.deleteCount = deleteCount
        self.retainedCount = retainedCount
    }
}

/// One run of the command that follows an apply, as the core records it.
public struct CommandRun: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let success: Bool
    public let stdout: String
    public let stderr: String
    public let addTimeMs: Int64

    enum CodingKeys: String, CodingKey {
        case id = "_id"
        case success, stdout, stderr
        case addTimeMs = "add_time_ms"
    }

    public var date: Date { Date(timeIntervalSince1970: TimeInterval(addTimeMs) / 1000) }
}
