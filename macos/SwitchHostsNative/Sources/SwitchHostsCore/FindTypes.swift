import Foundation

/// One match position inside an entry, as the core reports it.
public struct FindPosition: Decodable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    public let line: Int
    public let match: String
}

/// Matches found in one entry.
public struct FindItem: Decodable, Identifiable, Equatable, Sendable {
    public let itemId: String
    public let itemTitle: String
    public let itemType: String
    public let positions: [FindPosition]

    public var id: String { itemId }
    public var count: Int { positions.count }

    enum CodingKeys: String, CodingKey {
        case itemId = "item_id"
        case itemTitle = "item_title"
        case itemType = "item_type"
        case positions
    }
}

/// Result of a replace-all: which entries changed and how many matches.
public struct ReplaceOutcome: Decodable, Equatable, Sendable {
    public let itemIds: [String]
    public let replacedCount: Int

    enum CodingKeys: String, CodingKey {
        case itemIds = "item_ids"
        case replacedCount = "replaced_count"
    }
}

/// A remembered search: the keyword and the options it was run with.
public struct FindHistoryEntry: Codable, Equatable, Sendable {
    public let value: String
    public let isRegexp: Bool
    public let isIgnoreCase: Bool

    public init(value: String, isRegexp: Bool, isIgnoreCase: Bool) {
        self.value = value
        self.isRegexp = isRegexp
        self.isIgnoreCase = isIgnoreCase
    }

    enum CodingKeys: String, CodingKey {
        case value
        case isRegexp = "is_regexp"
        case isIgnoreCase = "is_ignore_case"
    }
}
