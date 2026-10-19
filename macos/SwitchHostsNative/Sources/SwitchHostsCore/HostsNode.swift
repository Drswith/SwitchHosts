import Foundation

/// One node of the hosts tree, in the same (legacy, snake_case) shape the
/// renderer uses. Optional fields may be absent in older data.
public struct HostsNode: Decodable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let type: String?
    public let on: Bool?
    public let isSys: Bool?
    public let children: [HostsNode]?
    /// Remote entries: "url" (one address) or "domain" (a list of domains).
    public let source: String?
    public let url: String?
    public let domains: [String]?
    /// Seconds between automatic refreshes; 0 or nil means manual only.
    public let refreshInterval: Int?
    /// Last successful refresh, as the core formats it.
    public let lastRefresh: String?
    /// Folders: whether the sidebar shows the folder closed.
    public let isCollapsed: Bool?
    /// Folders: 0 inherits the global choice mode, 1 allows one enabled child, 2 allows many.
    public let folderMode: Int?
    /// Groups: the ids of the local and remote entries the group lists.
    public let include: [String]?

    enum CodingKeys: String, CodingKey {
        case id, title, type, on, children, source, url, domains, include
        case isSys = "is_sys"
        case refreshInterval = "refresh_interval"
        case lastRefresh = "last_refresh"
        case isCollapsed = "is_collapsed"
        case folderMode = "folder_mode"
    }

    public var isFolder: Bool { type == "folder" }
    public var isRemote: Bool { type == "remote" }
    public var isGroup: Bool { type == "group" }
    /// Local entries are the only ones whose content is edited by hand. A
    /// missing type is local, as in older data.
    public var isLocal: Bool { type == nil || type == "local" }
    public var isOn: Bool { on ?? false }
    public var isClosed: Bool { isCollapsed ?? false }
}

/// One entry in the trashcan, as the core serialises it.
public struct TrashItem: Decodable, Identifiable, Equatable, Sendable {
    public let data: HostsNode
    public let parentId: String?
    public let addTimeMs: Double?

    public var id: String { data.id }

    enum CodingKeys: String, CodingKey {
        case data
        case parentId = "parent_id"
        case addTimeMs = "add_time_ms"
    }
}
