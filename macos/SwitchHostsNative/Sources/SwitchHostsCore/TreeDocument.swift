import Foundation

/// Pure edits on the hosts tree in its JSON shape. Works on untyped
/// dictionaries so fields this app does not model survive a save.
public enum TreeDocument {
    public typealias Node = [String: Any]

    /// Returns the node with `id` and the chain of ancestor ids, or nil.
    public static func find(_ id: String, in nodes: [Node]) -> (node: Node, ancestors: [String])? {
        for node in nodes {
            if node["id"] as? String == id {
                return (node, [])
            }
            if let children = node["children"] as? [Node],
               let found = find(id, in: children) {
                let ancestorId = node["id"] as? String ?? ""
                return (found.node, [ancestorId] + found.ancestors)
            }
        }
        return nil
    }

    /// Appends a new local entry under `parentID`, or at the top level when nil.
    /// Returns false if the parent is not a folder in the tree.
    @discardableResult
    public static func appendLocal(id: String, title: String, parentID: String?, to nodes: inout [Node]) -> Bool {
        let entry: Node = ["id": id, "type": "local", "title": title, "on": false]
        return append(entry, parentID: parentID, to: &nodes)
    }

    /// Appends an empty folder. `folderMode` 0 inherits the global choice mode,
    /// 1 allows one enabled child, 2 allows several.
    @discardableResult
    public static func appendFolder(id: String, title: String, folderMode: Int, parentID: String?, to nodes: inout [Node]) -> Bool {
        let entry: Node = [
            "id": id, "type": "folder", "title": title, "on": false,
            "folder_mode": folderMode, "children": [Node](),
        ]
        return append(entry, parentID: parentID, to: &nodes)
    }

    /// Appends a group that lists the entries in `include` (local and remote ids).
    @discardableResult
    public static func appendGroup(id: String, title: String, include: [String], parentID: String?, to nodes: inout [Node]) -> Bool {
        let entry: Node = ["id": id, "type": "group", "title": title, "on": false, "include": include]
        return append(entry, parentID: parentID, to: &nodes)
    }

    /// Sets which entries a group lists. Returns false if `id` is missing or is
    /// not a group.
    @discardableResult
    public static func setInclude(_ id: String, _ include: [String], in nodes: inout [Node]) -> Bool {
        mutate(id, in: &nodes) { node in
            guard node["type"] as? String == "group" else { return false }
            node["include"] = include
            return true
        }
    }

    /// Adds `entry` at the end of folder `parentID`, or of the top level when nil.
    private static func append(_ entry: Node, parentID: String?, to nodes: inout [Node]) -> Bool {
        guard let parentID else {
            nodes.append(entry)
            return true
        }
        return insert(entry, under: parentID, in: &nodes)
    }

    /// Appends a remote entry. Give `url` for a single address, or `domains`
    /// for a domain list; the core fetches or resolves it on refresh.
    @discardableResult
    public static func appendRemote(
        id: String,
        title: String,
        url: String?,
        domains: [String]?,
        refreshInterval: Int,
        parentID: String?,
        to nodes: inout [Node]
    ) -> Bool {
        var entry: Node = ["id": id, "type": "remote", "title": title, "on": false, "refresh_interval": refreshInterval]
        applyTarget(url: url, domains: domains, to: &entry)
        return append(entry, parentID: parentID, to: &nodes)
    }

    /// Changes where a remote entry gets its content from. Returns false if
    /// `id` is missing or is not a remote entry.
    @discardableResult
    public static func setRemoteTarget(_ id: String, url: String?, domains: [String]?, in nodes: inout [Node]) -> Bool {
        mutate(id, in: &nodes) { node in
            guard node["type"] as? String == "remote" else { return false }
            applyTarget(url: url, domains: domains, to: &node)
            return true
        }
    }

    /// Sets how often a remote entry refreshes, in seconds (0 = manual).
    @discardableResult
    public static func setRefreshInterval(_ id: String, seconds: Int, in nodes: inout [Node]) -> Bool {
        mutate(id, in: &nodes) { node in
            guard node["type"] as? String == "remote" else { return false }
            node["refresh_interval"] = seconds
            return true
        }
    }

    private static func applyTarget(url: String?, domains: [String]?, to entry: inout Node) {
        if let domains {
            entry["source"] = "domain"
            entry["domains"] = domains
            entry["url"] = ""
        } else {
            entry["source"] = "url"
            entry["url"] = url ?? ""
            entry.removeValue(forKey: "domains")
        }
    }

    /// Changes the title of `id`. Returns false if it does not exist.
    @discardableResult
    public static func rename(_ id: String, to title: String, in nodes: inout [Node]) -> Bool {
        mutate(id, in: &nodes) { node in
            node["title"] = title
            return true
        }
    }

    /// Removes `id` from the tree. Returns false if it does not exist.
    @discardableResult
    public static func remove(_ id: String, from nodes: inout [Node]) -> Bool {
        if let index = nodes.firstIndex(where: { $0["id"] as? String == id }) {
            nodes.remove(at: index)
            return true
        }
        for index in nodes.indices {
            if var children = nodes[index]["children"] as? [Node] {
                if remove(id, from: &children) {
                    nodes[index]["children"] = children
                    return true
                }
            }
        }
        return false
    }

    /// Moves `id` by `offset` positions among its siblings (-1 up, +1 down).
    /// Returns false at the edge of its list or when `id` does not exist.
    @discardableResult
    public static func moveSibling(_ id: String, by offset: Int, in nodes: inout [Node]) -> Bool {
        if let index = nodes.firstIndex(where: { $0["id"] as? String == id }) {
            let target = index + offset
            guard nodes.indices.contains(target) else { return false }
            nodes.swapAt(index, target)
            return true
        }
        for index in nodes.indices {
            if var children = nodes[index]["children"] as? [Node] {
                if moveSibling(id, by: offset, in: &children) {
                    nodes[index]["children"] = children
                    return true
                }
            }
        }
        return false
    }

    /// Sets a folder's choice mode: 0 inherits the global mode, 1 allows one
    /// enabled child, 2 allows several. Returns false if `id` is not a folder.
    @discardableResult
    public static func setFolderMode(_ id: String, mode: Int, in nodes: inout [Node]) -> Bool {
        mutate(id, in: &nodes) { node in
            guard node["type"] as? String == "folder" else { return false }
            node["folder_mode"] = mode
            return true
        }
    }

    /// Moves `id` (with its children) to the end of folder `parentID`, or to
    /// the end of the top level when `parentID` is nil. Returns false when `id`
    /// is missing, the target is not a folder, or the target is `id` itself or
    /// one of its descendants.
    @discardableResult
    public static func move(_ id: String, toFolder parentID: String?, in nodes: inout [Node]) -> Bool {
        guard let entry = find(id, in: nodes)?.node else { return false }
        if let parentID {
            if parentID == id { return false }
            if let children = entry["children"] as? [Node], find(parentID, in: children) != nil {
                return false
            }
            guard find(parentID, in: nodes)?.node["type"] as? String == "folder" else { return false }
        }
        remove(id, from: &nodes)
        guard let parentID else {
            nodes.append(entry)
            return true
        }
        return insert(entry, under: parentID, in: &nodes)
    }

    /// Where a dragged entry lands relative to the entry it is dropped on.
    public enum Placement: Equatable, Sendable {
        case before
        case after
        /// Into the target, which must be a folder.
        case inside
    }

    /// Moves `id` next to `targetID` (before or after it) or into it when the
    /// target is a folder. Returns false when either entry is missing, when the
    /// target is `id` itself or one of its descendants, or when `.inside` is
    /// asked for a non-folder.
    @discardableResult
    public static func move(_ id: String, relativeTo targetID: String, placement: Placement, in nodes: inout [Node]) -> Bool {
        if placement == .inside {
            return move(id, toFolder: targetID, in: &nodes)
        }
        guard id != targetID, let entry = find(id, in: nodes)?.node else { return false }
        if let children = entry["children"] as? [Node], find(targetID, in: children) != nil {
            return false
        }
        guard find(targetID, in: nodes) != nil else { return false }
        remove(id, from: &nodes)
        return insertSibling(entry, relativeTo: targetID, after: placement == .after, in: &nodes)
    }

    /// Places `entry` next to the sibling `targetID` in whichever list holds it.
    private static func insertSibling(_ entry: Node, relativeTo targetID: String, after: Bool, in nodes: inout [Node]) -> Bool {
        if let index = nodes.firstIndex(where: { $0["id"] as? String == targetID }) {
            nodes.insert(entry, at: after ? index + 1 : index)
            return true
        }
        for index in nodes.indices {
            if var children = nodes[index]["children"] as? [Node] {
                if insertSibling(entry, relativeTo: targetID, after: after, in: &children) {
                    nodes[index]["children"] = children
                    return true
                }
            }
        }
        return false
    }

    /// Applies `change` to the node with `id` and returns its result, or false if
    /// no node has that id.
    private static func mutate(_ id: String, in nodes: inout [Node], _ change: (inout Node) -> Bool) -> Bool {
        for index in nodes.indices {
            if nodes[index]["id"] as? String == id {
                return change(&nodes[index])
            }
            if var children = nodes[index]["children"] as? [Node] {
                if mutate(id, in: &children, change) {
                    nodes[index]["children"] = children
                    return true
                }
            }
        }
        return false
    }

    private static func insert(_ entry: Node, under parentID: String, in nodes: inout [Node]) -> Bool {
        for index in nodes.indices {
            if nodes[index]["id"] as? String == parentID {
                guard nodes[index]["type"] as? String == "folder" else { return false }
                var children = nodes[index]["children"] as? [Node] ?? []
                children.append(entry)
                nodes[index]["children"] = children
                return true
            }
            if var children = nodes[index]["children"] as? [Node] {
                if insert(entry, under: parentID, in: &children) {
                    nodes[index]["children"] = children
                    return true
                }
            }
        }
        return false
    }
}
