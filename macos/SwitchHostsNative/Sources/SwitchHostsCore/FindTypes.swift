import Foundation

/// One match position inside an entry, as the core reports it.
public struct FindPosition: Decodable, Equatable, Sendable {
    public let start: Int
    public let end: Int
    /// 1-based, as the core counts lines.
    public let line: Int
    public let match: String
    /// Text on the same line around the match, for the result row.
    public let before: String
    public let after: String

    enum CodingKeys: String, CodingKey {
        case start, end, line, match, before, after
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        start = try container.decode(Int.self, forKey: .start)
        end = try container.decode(Int.self, forKey: .end)
        line = try container.decode(Int.self, forKey: .line)
        match = try container.decode(String.self, forKey: .match)
        before = try container.decodeIfPresent(String.self, forKey: .before) ?? ""
        after = try container.decodeIfPresent(String.self, forKey: .after) ?? ""
    }
}

/// Matches found in one entry.
public struct FindItem: Decodable, Identifiable, Equatable, Sendable {
    public let itemId: String
    public let itemTitle: String
    public let itemType: String
    public let positions: [FindPosition]

    public var id: String { itemId }
    public var count: Int { positions.count }
    /// Only local entries can be replaced in; the core refuses the rest.
    public var isReadOnly: Bool { itemType != "local" }

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
