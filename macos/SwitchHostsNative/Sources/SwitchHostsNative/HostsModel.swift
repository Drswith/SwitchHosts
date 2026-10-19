import AppKit
import Foundation
import SwitchHostsCore
import UniformTypeIdentifiers

/// Drives the main window. All storage and system work runs in the Rust core
/// through `SwhCore`; this type only holds view state and sequences calls.
@MainActor
final class HostsModel: ObservableObject {
    @Published private(set) var tree: [HostsNode] = []
    /// The entry shown in the editor.
    @Published var selection: String?
    /// Every selected sidebar row. Usually just `selection`; several rows can be
    /// selected with ⌘ and ⇧, as in 5.0.2, to move them to the trash together.
    @Published private(set) var selectedIDs: Set<String> = []
    @Published var content: String = ""
    @Published private(set) var trashItems: [TrashItem] = []
    @Published var showTrash = false
    @Published var errorMessage: String?
    /// Menu bar title when "show title on tray" is on; nil otherwise.
    @Published private(set) var trayTitle: String?
    /// Shown in the window while a slow core call (a URL download) runs.
    @Published var busyMessage: String?
    @Published var showFind = false
    @Published var showImportURL = false
    @Published var showHistory = false
    /// The entry being created or edited; the window shows the entry sheet while set.
    @Published var entryPrompt: EntryPrompt?
    /// Set when a find result is shown; the editor selects and scrolls to it.
    @Published var reveal: EditorReveal?
    /// The address of a URL import that failed, so the error bar can retry it.
    @Published private(set) var retryImportURL: String?
    /// A newer release found by the startup update check, with its release page.
    @Published var updateNotice: (message: String, url: URL)?
    /// Set at launch when "hide at launch" is on; the window closes itself once shown.
    @Published var startsHidden = false
    /// Window and tray preferences, mirrored from the core so the views react to changes.
    @Published var useSystemWindowFrame = false
    /// Mirrors `hide_dock_icon`, so the tray can offer the opposite action.
    @Published private(set) var dockIconHidden = false
    @Published var trayMiniWindow = true
    @Published var leftPanelShown = true
    @Published var rightPanelShown = false
    @Published var leftPanelWidth: Double = 270
    @Published var rightPanelWidth: Double = 240

    /// Last content read from or written to the core for the selected entry.
    private(set) var savedContent: String = ""
    var isDirty: Bool { content != savedContent }

    private var core: SwhCore?
    private var eventTask: Task<Void, Never>?

    /// Events after which the tree on screen may be stale.
    private static let treeChangingEvents: Set<String> = [
        "system_hosts_updated",
        "tray_list_updated",
        "reload_list",
        "hosts_content_changed",
        "hosts_content_changed_batch",
    ]

    func start() async {
        guard core == nil else { return }
        do {
            let core = try SwhCore()
            self.core = core
            // Preferences that affect the process itself, applied at launch.
            let hideDock = try await core.call(Bool.self, "config_get", ["hide_dock_icon"])
            DockIcon.apply(hidden: hideDock)
            dockIconHidden = hideDock
            AppTheme.apply((try? await core.call(String.self, "config_get", ["theme"])) ?? "system")
            eventTask = Task { [weak self] in
                for await event in core.events where Self.treeChangingEvents.contains(event.name) {
                    await self?.reload()
                }
            }
            await reload()
            await recoverDataDirIfNeeded()
            // 5.0.2 opens on the system hosts file.
            if selection == nil {
                await select(Self.systemHostsID)
            }
            await applyStartupPreferences(core)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// When the recorded data folder could not be used at launch, asks what to
    /// do, as 5.0.2's recovery dialog does: use the default location, choose a
    /// new folder, or quit. Both fixes restart the app. The question repeats
    /// until one of them takes effect.
    private func recoverDataDirIfNeeded() async {
        guard let status = await dataDirStatus(), let kind = status.recoveryKind else { return }
        while true {
            let alert = NSAlert()
            alert.alertStyle = .warning
            if kind == "invalid" {
                alert.messageText = String(localized: "Data Location Unreadable")
                alert.informativeText = String(localized: "SwitchHosts could not determine where your data is stored because the saved location record is damaged. Your data has not been changed. Please choose how to proceed.")
            } else {
                alert.messageText = String(localized: "Data Directory Not Found")
                alert.informativeText = String(localized: "The data directory could not be found. It may have been moved or deleted. Please choose how to proceed.")
                if let path = status.recoveryPath {
                    alert.informativeText += "\n\n" + path
                }
            }
            alert.informativeText += "\n\n" + String(localized: "Default location: \(status.defaultDir)")
            alert.addButton(withTitle: String(localized: "Use Default Location"))
            alert.addButton(withTitle: String(localized: "Choose New Folder…"))
            alert.addButton(withTitle: String(localized: "Quit"))
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                if await resetDataDir() {
                    AppRelaunch.restart()
                    return
                }
            case .alertSecondButtonReturn:
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.canCreateDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = String(localized: "Choose")
                guard panel.runModal() == .OK, let url = panel.url,
                      let plan = await planDataDir(url) else { continue }
                // The old folder is gone, so there is nothing to copy. Picking the
                // default location is a reset, as in 5.0.2.
                let restart = plan.isDefault ? await resetDataDir() : await applyDataDir(url, copy: false)
                if restart {
                    AppRelaunch.restart()
                    return
                }
            default:
                NSApp.terminate(nil)
                return
            }
            // A failed fix is shown in the error bar; ask again.
            if let message = errorMessage {
                let failed = NSAlert()
                failed.messageText = String(localized: "Failed")
                failed.informativeText = message
                failed.runModal()
            }
        }
    }

    /// Preferences that act once at launch: quitting on close, hiding the window,
    /// refreshing remote entries, and checking for a newer release.
    private func applyStartupPreferences(_ core: SwhCore) async {
        let config = await loadConfig()
        AppBehavior.quitOnClose = config["quit_on_close"] as? Bool ?? false
        startsHidden = config["hide_at_launch"] as? Bool ?? false
        await loadPreferences()
        if config["refresh_remote_hosts_on_startup"] as? Bool == true {
            _ = try? await core.json("refresh_all_remote_hosts")
            await reload()
        }
        if config["auto_check_update"] as? Bool ?? true {
            let result = await checkForUpdate()
            if let url = result.url {
                updateNotice = (result.message, url)
            }
        }
    }

    /// Shows or hides the Dock icon and saves the choice (`hide_dock_icon`).
    func setDockIconHidden(_ hidden: Bool) async {
        DockIcon.apply(hidden: hidden)
        dockIconHidden = hidden
        await updateConfig(["hide_dock_icon": hidden])
    }

    /// Re-reads the window, panel, and tray preferences into the published values.
    func loadPreferences() async {
        let config = await loadConfig()
        useSystemWindowFrame = config["use_system_window_frame"] as? Bool ?? false
        trayMiniWindow = config["tray_mini_window"] as? Bool ?? true
        leftPanelShown = config["left_panel_show"] as? Bool ?? true
        rightPanelShown = config["right_panel_show"] as? Bool ?? false
        leftPanelWidth = (config["left_panel_width"] as? NSNumber)?.doubleValue ?? 270
        rightPanelWidth = (config["right_panel_width"] as? NSNumber)?.doubleValue ?? 240
    }

    /// Saves preferences through the core, then refreshes the mirrored values.
    func savePreference(_ patch: [String: Any]) async {
        await updateConfig(patch)
        await loadPreferences()
    }

    /// Shows or hides the sidebar and remembers it.
    func setLeftPanel(shown: Bool) {
        guard shown != leftPanelShown else { return }
        leftPanelShown = shown
        Task { await savePreference(["left_panel_show": shown]) }
    }

    /// Shows or hides the entry-information panel and remembers it.
    func setRightPanel(shown: Bool) {
        guard shown != rightPanelShown else { return }
        rightPanelShown = shown
        Task { await savePreference(["right_panel_show": shown]) }
    }

    func reload() async {
        guard let core else { return }
        do {
            tree = try await core.call([HostsNode].self, "get_list")
            let showTitle = (try? await core.call(Bool.self, "config_get", ["show_title_on_tray"])) ?? false
            trayTitle = TrayTitle.make(tree, show: showTitle)
            // The sidebar shows how many entries the trashcan holds.
            if let trash = try? await core.call([TrashItem].self, "get_trashcan_list") {
                trashItems = trash
            }
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // ---- selection and content --------------------------------------------

    /// Sidebar id for the read-only system hosts row.
    static let systemHostsID = "__system_hosts__"

    /// Whether the editor shows the read-only system hosts file.
    var isSystemHostsSelected: Bool { selection == Self.systemHostsID }

    /// Whether the selection is a folder (shown with its settings, not content).
    var isFolderSelected: Bool { selectedNode?.isFolder == true }

    /// Applies a sidebar selection of one or more rows. The row added last
    /// becomes the entry in the editor. The system hosts row is never part of
    /// a multiple selection. The rows update at once, so the list keeps what was
    /// clicked; the entry's content loads after.
    func changeSelection(to ids: Set<String>) {
        var ids = ids
        let added = ids.subtracting(selectedIDs)
        if added.contains(Self.systemHostsID) {
            ids = [Self.systemHostsID]
        } else if ids.count > 1 {
            ids.remove(Self.systemHostsID)
        }
        let primary = added.first(where: ids.contains)
            ?? (selection.map(ids.contains) == true ? selection : ids.first)
        let previous = selectedIDs
        selectedIDs = ids
        guard primary != selection else { return }
        Task {
            await select(primary, rows: ids)
            if selection != primary {
                // The user kept unsaved edits; the old rows stay selected.
                selectedIDs = previous
            }
        }
    }

    /// Select an entry and load its content. Folders have no content of their
    /// own. `rows` is the whole sidebar selection when several rows are selected.
    func select(_ id: String?, rows: Set<String>? = nil) async {
        guard await confirmDiscardIfDirty() else { return }
        selection = id
        selectedIDs = rows ?? (id.map { [$0] } ?? [])
        if id == Self.systemHostsID {
            await loadSystemHosts()
            return
        }
        guard let id, let node = TreeDocument.find(id, in: await rawList())?.node else {
            content = ""
            savedContent = ""
            return
        }
        // Folders and groups have no content of their own.
        if ["folder", "group"].contains(node["type"] as? String) {
            content = ""
            savedContent = ""
            return
        }
        await loadContent(for: id)
    }

    /// Reads the system hosts file through the core. Read-only in this view.
    func loadSystemHosts() async {
        guard let core else { return }
        do {
            let text = try await core.call(String.self, "get_system_hosts")
            content = text
            savedContent = text
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func saveContent() async {
        // Only local entries are edited by hand; the rest are read-only, as in 5.0.2.
        guard let core, let id = selection, selectedNode?.isLocal == true else { return }
        do {
            try await core.send("set_hosts_content", [id, content])
            savedContent = content
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func loadContent(for id: String) async {
        guard let core else { return }
        do {
            let text = try await core.call(String.self, "get_hosts_content", [id])
            content = text
            savedContent = text
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Asks before dropping unsaved edits. Returns false when the user cancels.
    private func confirmDiscardIfDirty() async -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard unsaved changes?")
        alert.informativeText = String(localized: "The edits to this entry have not been saved.")
        alert.addButton(withTitle: String(localized: "Discard"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    // ---- toggling ----------------------------------------------------------

    /// Flip an entry. The core applies the change to the system hosts file and
    /// applies the same folder and choice-mode rules the renderer uses.
    func toggle(_ node: HostsNode) async {
        guard let core else { return }
        // With no write mode saved yet, ask for one first, as 5.0.2 does; the
        // switch then goes ahead with the chosen mode.
        if (await loadConfig()["write_mode"] as? String ?? "").isEmpty {
            guard let mode = askWriteMode() else { return }
            await updateConfig(["write_mode": mode])
        }
        do {
            try await core.send("toggle_item", [node.id])
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    /// "append" or "overwrite", or nil when the user cancels.
    private func askWriteMode() -> String? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Set Write Mode")
        alert.informativeText = String(localized: "Append") + ": " + String(localized: "Append the new records to the end of the system hosts file.")
            + "\n" + String(localized: "Overwrite") + ": " + String(localized: "Overwrite the system hosts file with the new records.")
        alert.addButton(withTitle: String(localized: "Append"))
        alert.addButton(withTitle: String(localized: "Overwrite"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return "append"
        case .alertSecondButtonReturn: return "overwrite"
        default: return nil
        }
    }

    // ---- tree edits --------------------------------------------------------
    // Read the tree as JSON, edit it, and write it back with the read as the
    // guard. The core rejects the write if the tree changed in between.

    /// Creates an entry of any kind inside the selected folder, or at the top
    /// level. A new remote entry is fetched straight away.
    func addEntry(_ draft: EntryDraft) async {
        await editTree { list in
            let id = UUID().uuidString
            let parent = self.selectedFolderID(in: list)
            let added: Bool
            switch draft.kind {
            case .local:
                added = TreeDocument.appendLocal(id: id, title: draft.title, parentID: parent, to: &list)
            case .remote:
                added = TreeDocument.appendRemote(
                    id: id,
                    title: draft.title,
                    url: draft.url,
                    domains: draft.domains,
                    refreshInterval: draft.refreshInterval,
                    parentID: parent,
                    to: &list
                )
            case .group:
                added = TreeDocument.appendGroup(id: id, title: draft.title, include: draft.include, parentID: parent, to: &list)
            case .folder:
                added = TreeDocument.appendFolder(id: id, title: draft.title, folderMode: draft.folderMode, parentID: parent, to: &list)
            }
            guard added else {
                throw SwhError.command(String(localized: "Select a folder to add into, or select nothing for the top level."))
            }
            return id
        }
        if draft.kind == .remote, let id = selection, selectedNode?.isRemote == true {
            _ = await refreshRemote(id)
        }
    }

    /// Saves the sheet's fields for an existing entry. The kind does not change,
    /// as in 5.0.2.
    func updateEntry(_ id: String, _ draft: EntryDraft) async {
        await editTree { list in
            guard TreeDocument.rename(id, to: draft.title, in: &list) else {
                throw SwhError.command(String(localized: "The entry no longer exists."))
            }
            let saved: Bool
            switch draft.kind {
            case .local:
                saved = true
            case .remote:
                saved = TreeDocument.setRemoteTarget(id, url: draft.url, domains: draft.domains, in: &list)
                    && TreeDocument.setRefreshInterval(id, seconds: draft.refreshInterval, in: &list)
            case .group:
                saved = TreeDocument.setInclude(id, draft.include, in: &list)
            case .folder:
                saved = TreeDocument.setFolderMode(id, mode: draft.folderMode, in: &list)
            }
            guard saved else {
                throw SwhError.command(String(localized: "The entry no longer exists."))
            }
            return id
        }
    }

    /// Moves an entry up (-1) or down (+1) among its siblings and saves the tree.
    func move(_ id: String, by offset: Int) async {
        await editTree { list in
            guard TreeDocument.moveSibling(id, by: offset, in: &list) else {
                throw SwhError.command(String(localized: "The entry is already at the edge of its list."))
            }
            return id
        }
    }

    /// Remembers whether a folder is shown closed. Does not change the selection.
    func setCollapsed(_ id: String, _ collapsed: Bool) async {
        await editTree(selectingEdited: false) { list in
            guard TreeDocument.setCollapsed(id, collapsed, in: &list) else {
                throw SwhError.command(String(localized: "The folder no longer exists."))
            }
            return id
        }
    }

    /// Sets a folder's choice mode: 0 inherits the global mode, 1 single, 2 multiple.
    func setFolderMode(_ id: String, mode: Int) async {
        await editTree { list in
            guard TreeDocument.setFolderMode(id, mode: mode, in: &list) else {
                throw SwhError.command(String(localized: "The folder no longer exists."))
            }
            return id
        }
    }

    /// Moves an entry (and its children) into a folder, or to the top level when nil.
    func move(_ id: String, toFolder parentID: String?) async {
        await editTree { list in
            guard TreeDocument.move(id, toFolder: parentID, in: &list) else {
                throw SwhError.command(String(localized: "That folder cannot take the entry."))
            }
            return id
        }
    }

    /// Folders the entry `id` can move into, with their depth for indentation.
    /// The entry itself and its own children are left out.
    func folderOptions(excluding id: String) -> [FolderOption] {
        var options: [FolderOption] = []
        func walk(_ nodes: [HostsNode], depth: Int) {
            for node in nodes where node.id != id {
                guard node.isFolder else { continue }
                options.append(FolderOption(id: node.id, title: node.title ?? node.id, depth: depth))
                walk(node.children ?? [], depth: depth + 1)
            }
        }
        walk(tree, depth: 0)
        return options
    }

    /// Drops a dragged entry before, after, or into the entry `targetID`.
    /// The selection stays where it is.
    func drop(_ id: String, onto targetID: String, placement: TreeDocument.Placement) async {
        // Text dropped from another app can name anything; only entries in the tree move.
        guard node(withID: id) != nil else { return }
        await editTree(selectingEdited: false) { list in
            guard TreeDocument.move(id, relativeTo: targetID, placement: placement, in: &list) else {
                throw SwhError.command(String(localized: "That entry cannot be moved there."))
            }
            return id
        }
    }

    /// Moves an entry to the trashcan. It stays restorable until the trashcan
    /// entry is deleted. When `id` is one of several selected rows, all of them
    /// move, as in 5.0.2.
    func moveToTrash(_ id: String) async {
        let ids = selectedIDs.contains(id) ? trashableSelection : [id]
        await moveToTrash(ids: ids)
    }

    /// The selected rows that can go to the trashcan (not the system hosts row).
    var trashableSelection: [String] {
        let ids = selectedIDs.isEmpty ? Set(selection.map { [$0] } ?? []) : selectedIDs
        return allNodes.map(\.id).filter { ids.contains($0) }
    }

    func moveToTrash(ids: [String]) async {
        guard let core, !ids.isEmpty else { return }
        do {
            if ids.count == 1 {
                try await core.send("move_to_trashcan", [ids[0]])
            } else {
                try await core.send("move_many_to_trashcan", [ids])
            }
            if let current = selection, ids.contains(current) {
                selection = nil
                content = ""
                savedContent = ""
            }
            selectedIDs.subtract(ids)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    /// Read-only update check. Returns a message and, when a newer release
    /// exists, the release page. Nothing is downloaded.
    func checkForUpdate() async -> (message: String, url: URL?) {
        guard let core else { return ("", nil) }
        do {
            let value = try await core.json("check_for_update") as? [String: Any] ?? [:]
            let latest = value["latest"] as? String ?? ""
            let current = value["current"] as? String ?? ""
            if value["update_available"] as? Bool == true {
                let url = (value["url"] as? String).flatMap(URL.init(string:))
                return (String(localized: "Version \(latest) is available (you have \(current))."), url)
            }
            return (String(localized: "You are up to date (\(current))."), nil)
        } catch {
            return (error.localizedDescription, nil)
        }
    }

    // ---- preferences -------------------------------------------------------

    /// Runs a privileged-helper command (`helper_status`, `helper_install`, ...).
    /// Returns the status code, or the failure message when the core reports one.
    func helperCommand(_ command: String) async -> String {
        guard let core else { return "" }
        do {
            let value = try await core.json(command) as? [String: Any] ?? [:]
            if let message = value["message"] as? String, !message.isEmpty {
                return CoreText.localized(message)
            }
            return value["status"] as? String ?? ""
        } catch {
            return error.localizedDescription
        }
    }

    /// Every preference as the core stores it (flat, snake_case keys).
    func loadConfig() async -> [String: Any] {
        guard let core else { return [:] }
        return (try? await core.json("config_all") as? [String: Any]) ?? [:]
    }

    /// Persists a partial preference update. Host side effects are the caller's job.
    func updateConfig(_ patch: [String: Any]) async {
        guard let core else { return }
        do {
            try await core.send("config_update", [patch])
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Applies the local HTTP API preference. Returns the listener status text.
    func configureHTTPAPI(on: Bool, port: Int, onlyLocal: Bool) async -> String {
        guard let core else { return "" }
        do {
            let status = try await core.json("http_api_configure", [on, port, onlyLocal]) as? [String: Any] ?? [:]
            errorMessage = nil
            if status["running"] as? Bool == true {
                return String(localized: "Listening on \(status["address"] as? String ?? "")")
            }
            if let error = status["error"] as? [String: Any], let reason = error["reason"] as? String {
                return String(localized: "Not running: \(CoreText.localized(reason))")
            }
            return on ? String(localized: "Not running.") : String(localized: "Off.")
        } catch {
            errorMessage = error.localizedDescription
            return String(localized: "Not running.")
        }
    }

    // ---- find and replace --------------------------------------------------

    /// Matches for `keyword` across every entry. Empty when the core reports an error.
    func findMatches(keyword: String, regexp: Bool, ignoreCase: Bool) async -> [FindItem] {
        guard let core else { return [] }
        do {
            let options: [String: Any] = ["is_regexp": regexp, "is_ignore_case": ignoreCase]
            let items = try await core.call([FindItem].self, "find_by", [keyword, options])
            errorMessage = nil
            return items
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Replaces one match. The core checks that the text at `start..<end` still
    /// equals `expected`, so a stale result cannot overwrite newer content.
    func replaceOne(_ hit: FindItem, position: FindPosition, replacement: String) async -> Bool {
        guard let core else { return false }
        do {
            let args: [String: Any] = [
                "item_id": hit.itemId,
                "start": position.start,
                "end": position.end,
                "expected": position.match,
                "replace_to": replacement,
            ]
            let replaced = try await core.call(Bool.self, "find_replace_one", [args])
            errorMessage = nil
            await reload()
            if selection == hit.itemId {
                await loadContent(for: hit.itemId)
            }
            return replaced
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Selects the entry of a find result and asks the editor to select the match.
    func show(_ item: FindItem, _ position: FindPosition) async {
        await select(item.itemId)
        guard selection == item.itemId else { return }
        let length = max(0, position.end - position.start)
        reveal = EditorReveal(range: NSRange(location: position.start, length: length))
    }

    /// Recent searches, newest last, as the core keeps them.
    func findHistory() async -> [FindHistoryEntry] {
        guard let core else { return [] }
        return (try? await core.call([FindHistoryEntry].self, "find_get_history")) ?? []
    }

    func recordFind(keyword: String, regexp: Bool, ignoreCase: Bool) async {
        guard let core, !keyword.isEmpty else { return }
        let entry: [String: Any] = ["value": keyword, "is_regexp": regexp, "is_ignore_case": ignoreCase]
        try? await core.send("find_add_history", [entry])
    }

    /// Replacement texts, newest last, as the core keeps them.
    func replaceHistory() async -> [String] {
        guard let core else { return [] }
        return (try? await core.call([String].self, "find_get_replace_history")) ?? []
    }

    func recordReplace(_ text: String) async {
        guard let core, !text.isEmpty else { return }
        try? await core.send("find_add_replace_history", [text])
    }

    /// Replaces every match and refreshes the selected entry if it changed.
    func replaceAll(keyword: String, regexp: Bool, ignoreCase: Bool, replacement: String) async -> Int {
        guard let core else { return 0 }
        do {
            let options: [String: Any] = ["is_regexp": regexp, "is_ignore_case": ignoreCase]
            let outcome = try await core.call(ReplaceOutcome.self, "find_replace_all", [keyword, options, replacement])
            errorMessage = nil
            await reload()
            if let id = selection, outcome.itemIds.contains(id) {
                await loadContent(for: id)
            }
            return outcome.replacedCount
        } catch {
            errorMessage = error.localizedDescription
            return 0
        }
    }

    // ---- remote entries ----------------------------------------------------

    /// The tree node with `id`, at any depth.
    func node(withID id: String) -> HostsNode? {
        func find(_ nodes: [HostsNode]) -> HostsNode? {
            for node in nodes {
                if node.id == id { return node }
                if let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        return find(tree)
    }

    var selectedNode: HostsNode? { selection.flatMap { node(withID: $0) } }
    var isRemoteSelected: Bool { selectedNode?.isRemote == true }

    /// Every entry in the tree, depth first.
    var allNodes: [HostsNode] {
        func walk(_ nodes: [HostsNode]) -> [HostsNode] {
            nodes.flatMap { [$0] + walk($0.children ?? []) }
        }
        return walk(tree)
    }

    /// The entries a group lists that still exist, in the group's order.
    func includedNodes(of group: HostsNode) -> [HostsNode] {
        (group.include ?? []).compactMap { node(withID: $0) }
    }

    /// Fetches a remote entry's content through the core. Failures keep the
    /// previous content and are shown to the user.
    @discardableResult
    func refreshRemote(_ id: String) async -> Bool {
        guard let core else { return false }
        do {
            let result = try await core.json("refresh_remote_hosts", [id]) as? [String: Any] ?? [:]
            await reload()
            if selection == id {
                await loadContent(for: id)
            }
            if result["success"] as? Bool == true {
                errorMessage = nil
                return true
            }
            errorMessage = (result["message"] as? String).map(CoreText.localized) ?? String(localized: "Refresh failed.")
            return false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // ---- data directory ----------------------------------------------------

    func dataDirStatus() async -> DataDirStatus? {
        guard let core else { return nil }
        do {
            return try await core.call(DataDirStatus.self, "get_data_dir_status")
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// What the chosen folder would become. Nothing is created or copied.
    func planDataDir(_ url: URL) async -> DataDirPlan? {
        guard let core else { return nil }
        do {
            let plan = try await core.call(DataDirPlan.self, "data_dir_plan", [url.path])
            errorMessage = nil
            return plan
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Switches the data folder. Returns true when the app must restart to use it.
    func applyDataDir(_ url: URL, copy: Bool) async -> Bool {
        guard let core else { return false }
        do {
            let value = try await core.json("apply_data_dir", [url.path, copy]) as? [String: Any] ?? [:]
            errorMessage = nil
            return value["restart"] as? Bool ?? false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Returns to the default data folder. Returns true when the app must restart.
    func resetDataDir() async -> Bool {
        guard let core else { return false }
        do {
            let value = try await core.json("reset_data_dir") as? [String: Any] ?? [:]
            errorMessage = nil
            return value["restart"] as? Bool ?? false
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    // ---- command after apply -----------------------------------------------

    /// Recorded runs of the after-apply command, newest first.
    func commandRuns() async -> [CommandRun] {
        guard let core else { return [] }
        do {
            let items = try await core.call([CommandRun].self, "cmd_get_history_list")
            errorMessage = nil
            return Array(items.reversed())
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    func deleteCommandRun(_ id: String) async {
        guard let core else { return }
        do {
            try await core.send("cmd_delete_history_item", [id])
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func clearCommandRuns() async {
        guard let core else { return }
        do {
            try await core.send("cmd_clear_history")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // ---- system hosts history ----------------------------------------------

    /// Saved states of the system hosts file, newest first.
    func applyHistory() async -> [ApplyRecord] {
        guard let core else { return [] }
        do {
            let items = try await core.call([ApplyRecord].self, "get_apply_history")
            errorMessage = nil
            return Array(items.reversed())
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    /// Removes one saved state. Returns false if it was already gone.
    func deleteApplyRecord(_ id: String) async -> Bool {
        guard let core else { return false }
        do {
            let removed = try await core.call(Bool.self, "delete_apply_history_item", [id])
            errorMessage = nil
            return removed
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func clearApplyHistory() async {
        guard let core else { return }
        do {
            try await core.send("clear_apply_history")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Changes how many saved states are kept. Returns a preview when the change
    /// would delete records and `confirmation` is nil; nothing changes until the
    /// same preview is passed back. Returns nil once the limit is applied.
    @discardableResult
    func setHistoryLimit(_ limit: Int, confirmation: HistoryLimitPreview? = nil) async -> HistoryLimitPreview? {
        guard let core else { return nil }
        var request: [String: Any] = ["limit": limit]
        if let confirmation {
            request["confirmation"] = [
                "previous_limit": confirmation.previousLimit,
                "delete_count": confirmation.deleteCount,
            ]
        } else {
            request["confirmation"] = NSNull()
        }
        do {
            let value = try await core.json("update_apply_history_limit", [request]) as? [String: Any] ?? [:]
            errorMessage = nil
            guard value["confirmation_required"] as? Bool == true else { return nil }
            return HistoryLimitPreview(
                limit: limit,
                previousLimit: value["previous_limit"] as? Int ?? 0,
                deleteCount: value["delete_count"] as? Int ?? 0,
                retainedCount: value["retained_count"] as? Int ?? 0
            )
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Whether the core records a state on every change to the system hosts file.
    func historySettings() async -> (enabled: Bool, limit: Int) {
        let config = await loadConfig()
        return (config["history_enabled"] as? Bool ?? true, config["history_limit"] as? Int ?? 50)
    }

    // ---- backup import and export ------------------------------------------

    /// A staged import waiting for the user to choose how to apply it.
    struct PendingImport: Identifiable, Equatable {
        let id: String
        let name: String
        let topLevelIDs: [String]
        let count: Int
    }

    @Published var pendingImport: PendingImport?

    func exportBackup(to url: URL) async {
        guard let core else { return }
        do {
            _ = try await core.json("export_data", [url.path])
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Parses the backup and stages it. Nothing is written until `commitImport`.
    func beginImport(from url: URL) async {
        guard let core else { return }
        do {
            let value = try await core.json("import_file", [url.path]) as? [String: Any] ?? [:]
            stagePendingImport(value, fallbackName: url.deletingPathExtension().lastPathComponent)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Downloads a backup from an http(s) address and stages it. The core does
    /// the download and the same checks as a file import.
    func beginImport(fromURL text: String) async {
        guard let core else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            errorMessage = String(localized: "Enter an http:// or https:// address.")
            return
        }
        busyMessage = String(localized: "Downloading the backup…")
        defer { busyMessage = nil }
        do {
            let value = try await core.json("import_url", [url.absoluteString]) as? [String: Any] ?? [:]
            stagePendingImport(value, fallbackName: url.host ?? "import")
            errorMessage = nil
            retryImportURL = nil
        } catch {
            errorMessage = error.localizedDescription
            retryImportURL = url.absoluteString
        }
    }

    /// Tries the last failed URL import again.
    func retryURLImport() async {
        guard let text = retryImportURL else { return }
        await beginImport(fromURL: text)
    }

    private func stagePendingImport(_ value: [String: Any], fallbackName: String) {
        let list = value["list"] as? [TreeDocument.Node] ?? []
        pendingImport = PendingImport(
            id: value["id"] as? String ?? "",
            name: value["name"] as? String ?? fallbackName,
            topLevelIDs: list.compactMap { $0["id"] as? String },
            count: list.count
        )
    }

    /// Save panel for a JSON backup, then the core writes it.
    func exportBackupWithPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "switchhosts_backup.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await exportBackup(to: url) }
    }

    /// Open panel for a JSON backup. The core parses it and stages a preview.
    func importBackupWithPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await beginImport(from: url) }
    }

    /// Applies the staged import. `mode` is "append" or "replace".
    func commitImport(mode: String) async {
        guard let core, let pending = pendingImport else { return }
        do {
            try await core.send("import_commit", [[
                "id": pending.id,
                "mode": mode,
                "selected": pending.topLevelIDs,
                "confirmed": true,
            ]])
            pendingImport = nil
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    func cancelImport() async {
        guard let core, let pending = pendingImport else { return }
        try? await core.send("import_discard", [pending.id])
        pendingImport = nil
    }

    /// Runs `edit` on the current tree and saves it with the read as the guard.
    /// The edited entry becomes the selection unless `selectingEdited` is false.
    private func editTree(selectingEdited: Bool = true, _ edit: (inout [TreeDocument.Node]) throws -> String) async {
        guard let core else { return }
        do {
            let before = await rawList()
            var list = before
            let touchedID = try edit(&list)
            try await core.send("set_list", [list, before])
            await reload()
            errorMessage = nil
            // Select through `select` so the editor shows the edited entry's
            // own content, not the previous entry's.
            if selectingEdited, selection != touchedID {
                await select(touchedID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The tree as untyped JSON. Empty when the core cannot be reached.
    private func rawList() async -> [TreeDocument.Node] {
        guard let core else { return [] }
        return (try? await core.json("get_list") as? [TreeDocument.Node]) ?? []
    }

    private func selectedFolderID(in list: [TreeDocument.Node]) -> String? {
        guard let id = selection,
              let found = TreeDocument.find(id, in: list),
              (found.node["type"] as? String) == "folder" else {
            return nil
        }
        return id
    }

    // ---- trashcan ----------------------------------------------------------

    func loadTrash() async {
        guard let core else { return }
        do {
            trashItems = try await core.call([TrashItem].self, "get_trashcan_list")
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// The content of a trashed entry, shown read-only. Folders and groups have none.
    func trashContent(_ item: TrashItem) async -> String {
        guard let core, item.data.isLocal || item.data.isRemote else { return "" }
        return (try? await core.call(String.self, "get_hosts_content", [item.id])) ?? ""
    }

    func restore(_ item: TrashItem) async {
        await trashAction("restore_item_from_trashcan", item.id)
    }

    /// Deletes a trashed entry for good, after the same confirmation as 5.0.2.
    func deleteForever(_ item: TrashItem) async {
        guard confirmDelete(String(localized: "Do you want to delete this item completely?")) else { return }
        await trashAction("delete_item_from_trashcan", item.id)
    }

    /// Empties the trashcan, after the same confirmation as 5.0.2.
    func clearTrash() async {
        guard confirmDelete(String(localized: "Are you sure you want to empty the trashcan?")) else { return }
        guard let core else { return }
        do {
            try await core.send("clear_trashcan")
            trashItems = []
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await reload()
    }

    /// Asks before a permanent delete. Returns false when the user cancels.
    private func confirmDelete(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func trashAction(_ command: String, _ id: String) async {
        guard let core else { return }
        do {
            try await core.send(command, [id])
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
        await loadTrash()
        await reload()
    }
}

/// A folder offered as a move target, indented by its depth in the tree.
struct FolderOption: Identifiable, Equatable {
    let id: String
    let title: String
    let depth: Int
}

/// A range the editor should select and scroll to. Each value is unique, so
/// showing the same match twice still moves the editor.
struct EditorReveal: Equatable {
    let token = UUID()
    let range: NSRange
}
