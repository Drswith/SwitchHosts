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
    /// The sidebar view the list shows. Views only filter; nothing is written.
    @Published private(set) var sidebar: SidebarItem = .system
    /// The search field above the list; it filters the list by title.
    @Published var listQuery = ""
    /// Saved states of the system hosts file, newest first, for the System Hosts view.
    @Published private(set) var historyRecords: [ApplyRecord] = []
    /// Lines in each local entry, for the list's second line.
    @Published private(set) var lineCounts: [String: Int] = [:]
    @Published var errorMessage: String?
    /// Menu bar title when "show title on tray" is on; nil otherwise.
    @Published private(set) var trayTitle: String?
    /// Shown in the window while a slow core call (a URL download) runs.
    @Published var busyMessage: String?
    @Published var showFind = false
    @Published var showImportURL = false
    /// The entry being created or edited; the window shows the entry sheet while set.
    @Published var entryPrompt: EntryPrompt?
    /// Set when a find result is shown; the editor selects and scrolls to it.
    @Published var reveal: EditorReveal?
    /// The address of a URL import that failed, so the error bar can retry it.
    @Published private(set) var retryImportURL: String?
    /// A newer release found by the startup update check, with its release page.
    @Published var updateNotice: (message: String, url: URL)?
    /// Window and tray preferences, mirrored from the core so the views react to changes.
    @Published var useSystemWindowFrame = false
    /// Mirrors `hide_dock_icon`, so the tray can offer the opposite action.
    @Published private(set) var dockIconHidden = false
    @Published var trayMiniWindow = true
    @Published var leftPanelShown = true
    /// The saved write mode ("append", "overwrite", or empty before the first apply).
    @Published private(set) var writeMode = ""
    /// The entry being dragged, set when a drag starts. Only a hint for how a
    /// row highlights under the pointer; the drop reads the id it carries.
    var draggingID: String?

    /// Last content read from or written to the core for the selected entry.
    private(set) var savedContent: String = ""
    /// The entry whose own text `content` holds. Nil while the selection's text
    /// is loading or after it failed to load, so nothing left in the editor is
    /// saved into the wrong entry.
    private(set) var contentID: String?
    /// Counts content loads. Only the newest may fill the editor, so a slow
    /// load cannot land after a newer selection.
    private var contentLoad = 0
    /// Whether the editor holds edits that are not saved yet. Local entries
    /// save themselves shortly after typing stops (see `flushAutosave`).
    var isDirty: Bool { content != savedContent }
    /// The save that was started last. Saves run one after another, so an
    /// older text can never land after a newer one.
    private var lastSave: Task<Bool, Never>?
    /// The error the last background load (list, history, trash) showed. A
    /// load that succeeds clears only that one, never an error an action has
    /// just reported before reloading.
    private var loadError: String?
    /// Entries whose new content waits to be applied to the system file, and
    /// whether the enabled order changed; see `reapplyChangedContent`.
    private var pendingReapplyIDs: Set<String> = []
    private var pendingReapplyOrder = false
    private var isReapplying = false

    private var core: SwhCore?
    /// Set when `start` runs, so the launch work happens once.
    private var started = false
    private var eventTask: Task<Void, Never>?
    /// Where the window's own view state is kept (not the core's config, so the
    /// data stays the same as 5.0.2's).
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Events after which the tree on screen may be stale.
    private static let treeChangingEvents: Set<String> = [
        "system_hosts_updated",
        "tray_list_updated",
        "reload_list",
        "hosts_content_changed",
        "hosts_content_changed_batch",
    ]

    /// Events naming entries whose content changed, such as a remote refresh.
    private static let contentChangingEvents: Set<String> = [
        "hosts_content_changed",
        "hosts_content_changed_batch",
    ]

    /// The entry ids a content event names: one for `hosts_content_changed`,
    /// a list for the batch event.
    static func changedIDs(in event: SwhEvent) -> [String] {
        guard let envelope = try? JSONSerialization.jsonObject(with: event.payload) as? [String: Any],
              let first = (envelope["_args"] as? [Any])?.first else { return [] }
        if let id = first as? String { return [id] }
        return first as? [String] ?? []
    }

    /// Opens the core while the app launches, before any window exists, and
    /// returns the `hide_at_launch` preference, so the main window need not be
    /// made at all. A core that cannot be opened is reported by `start`.
    func openAtLaunch() -> Bool {
        guard core == nil, let core = try? SwhCore() else { return false }
        self.core = core
        return (try? core.callNow(Bool.self, "config_get", ["hide_at_launch"])) ?? false
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            let core = try self.core ?? SwhCore()
            self.core = core
            // Preferences that affect the process itself, applied at launch.
            let hideDock = try await core.call(Bool.self, "config_get", ["hide_dock_icon"])
            DockIcon.apply(hidden: hideDock)
            dockIconHidden = hideDock
            AppTheme.apply((try? await core.call(String.self, "config_get", ["theme"])) ?? "system")
            eventTask = Task { [weak self] in
                for await event in core.events {
                    if Self.treeChangingEvents.contains(event.name) {
                        await self?.reload()
                    }
                    if Self.contentChangingEvents.contains(event.name) {
                        self?.reapplyChangedContent(Self.changedIDs(in: event))
                    }
                }
            }
            await reload()
            await recoverDataDirIfNeeded()
            // Quitting waits for unsaved edits to be written.
            AppBehavior.hasUnsavedEdits = { [weak self] in
                guard let self else { return false }
                return self.isDirty && self.selectedNode?.isLocal == true
            }
            AppBehavior.beforeQuit = { [weak self] in
                await self?.flushAutosave(askOnFailure: true) ?? true
            }
            // The view from last time, or System Hosts with the current file
            // selected, as 5.0.2 opens on it.
            if selection == nil {
                await showSidebar(savedSidebar() ?? .system)
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

    /// Preferences that act once at launch: quitting on close, refreshing
    /// remote entries, and checking for a newer release. Hiding the window is
    /// decided earlier, in `openAtLaunch`.
    private func applyStartupPreferences(_ core: SwhCore) async {
        let config = await loadConfig()
        AppBehavior.quitOnClose = config["quit_on_close"] as? Bool ?? false
        // Earlier native builds saved locales 5.0.2 cannot read, which breaks
        // its window on the shared data; save the names it uses instead.
        if let locale = config["locale"] as? String, let fixed = Self.legacyLocales[locale] {
            await updateConfig(["locale": fixed])
        }
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

    /// Locales earlier native builds saved, and the 5.0.2 names for them.
    static let legacyLocales = ["zh_CN": "zh", "en_US": "en"]

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
        writeMode = config["write_mode"] as? String ?? ""
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
            // A folder view whose folder went away falls back to all entries.
            if case .folder(let id) = sidebar, node(withID: id)?.isFolder != true {
                setSidebar(.all)
            }
            if sidebar == .system {
                await loadHistory()
            }
            // An entry removed elsewhere (another window, the HTTP API) leaves
            // nothing to show.
            if let id = selection, node(withID: id) == nil, id != Self.systemHostsID,
               !id.hasPrefix("history:"), !id.hasPrefix("trash:") {
                selection = nil
                clearContent()
            }
            selectedIDs = selectedIDs.filter { node(withID: $0) != nil || $0 == selection }
            refreshLineCounts()
            clearLoadError()
        } catch {
            showLoadError(error)
        }
    }

    /// Shows an error from a background load, remembering it as that load's own.
    private func showLoadError(_ error: Error) {
        errorMessage = error.localizedDescription
        loadError = errorMessage
    }

    /// Clears the error a background load showed earlier, if it is still the one shown.
    private func clearLoadError() {
        if let loadError, errorMessage == loadError {
            errorMessage = nil
        }
        loadError = nil
    }

    /// Applies the saved selection again after entry content changed (or,
    /// with nil, after the enabled order changed), as 5.0.2 does. The core
    /// writes only when one of `ids` is switched on and a write mode is set.
    /// Requests made while one runs are merged into the next.
    func reapplyChangedContent(_ ids: [String]?) {
        if let ids {
            guard !ids.isEmpty else { return }
            pendingReapplyIDs.formUnion(ids)
        } else {
            pendingReapplyOrder = true
        }
        guard !isReapplying else { return }
        isReapplying = true
        Task { await runPendingReapplies() }
    }

    private func runPendingReapplies() async {
        defer { isReapplying = false }
        while let core, pendingReapplyOrder || !pendingReapplyIDs.isEmpty {
            // A changed order applies whatever is on; otherwise only changes to enabled entries do.
            let args: [Any] = pendingReapplyOrder ? [] : [Array(pendingReapplyIDs)]
            pendingReapplyOrder = false
            pendingReapplyIDs = []
            do {
                try await core.send("reapply_saved_selection", args)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    // ---- sidebar views -----------------------------------------------------

    private static let sidebarKey = "SidebarSelection"

    /// Shows a sidebar view. The list keeps its selection when the view lists
    /// it; otherwise the first row is selected (for System Hosts, the current
    /// file, as 5.0.2 opens on it).
    func showSidebar(_ item: SidebarItem) async {
        guard await flushAutosave(askOnFailure: true) else { return }
        if item != sidebar {
            listQuery = ""
        }
        setSidebar(item)
        switch item {
        case .system: await loadHistory()
        case .trash: await loadTrash()
        default: break
        }
        let rows = listedRowIDs
        if let current = selection, rows.contains(current) {
            selectedIDs.formIntersection(rows)
            return
        }
        await select(rows.first)
    }

    /// Changes the view and remembers it, without touching the selection.
    private func setSidebar(_ item: SidebarItem) {
        sidebar = item
        defaults.set(item.storageValue, forKey: Self.sidebarKey)
    }

    /// The view remembered from last time, if it still exists.
    private func savedSidebar() -> SidebarItem? {
        guard let item = defaults.string(forKey: Self.sidebarKey).flatMap(SidebarItem.init(storageValue:)) else {
            return nil
        }
        if case .folder(let id) = item, node(withID: id)?.isFolder != true { return nil }
        return item
    }

    /// Entry counts for the sidebar.
    var counts: Library.Counts { Library.counts(in: tree) }

    /// Every folder, depth first, with its depth for indentation.
    var folderRows: [FolderOption] { Library.folders(in: tree) }

    /// The tree entries the list shows for the current view, after the search.
    var listedEntries: [HostsNode] {
        Library.matching(Library.rows(for: sidebar, in: tree), query: listQuery)
    }

    /// The saved states the System Hosts view lists, after the search.
    var listedHistory: [ApplyRecord] {
        let query = listQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return historyRecords }
        return historyRecords.filter { Self.snapshotTitle($0).localizedStandardContains(query) }
    }

    /// The trashed entries the Trash view lists, after the search.
    var listedTrash: [TrashItem] {
        let query = listQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return trashItems }
        return trashItems.filter { ($0.data.title ?? $0.id).localizedStandardContains(query) }
    }

    /// The ids of the list's rows, top to bottom.
    var listedRowIDs: [String] {
        switch sidebar {
        case .system:
            return [Self.systemHostsID] + listedHistory.map { Self.historyRowID($0.id) }
        case .trash:
            return listedTrash.map { Self.trashRowID($0.id) }
        default:
            return listedEntries.map(\.id)
        }
    }

    /// Whether the entry being dragged may land on or next to `targetID`:
    /// never on itself or anywhere inside its own subtree.
    func canDrop(on targetID: String) -> Bool {
        guard let dragged = draggingID else { return true }
        return !Library.isInSubtree(targetID, of: dragged, in: tree)
    }

    /// The folder that directly holds `id`, or nil at the top level.
    func parentFolder(of id: String) -> HostsNode? {
        Library.parent(of: id, in: tree)
    }

    /// Lines in an entry's text, as the editor's gutter numbers them.
    func lineCount(of id: String) -> Int? {
        id == selection ? Library.lineCount(of: content) : lineCounts[id]
    }

    private var lineCountTask: Task<Void, Never>?

    /// Re-reads the text of every local entry to count its lines.
    private func refreshLineCounts() {
        guard let core else { return }
        let ids = Library.entries(in: tree).filter(\.isLocal).map(\.id)
        lineCountTask?.cancel()
        lineCountTask = Task {
            var counts: [String: Int] = [:]
            for id in ids {
                guard !Task.isCancelled else { return }
                if let text = try? await core.call(String.self, "get_hosts_content", [id]) {
                    counts[id] = Library.lineCount(of: text)
                }
            }
            guard !Task.isCancelled else { return }
            lineCounts = counts
        }
    }

    // ---- list rows ---------------------------------------------------------

    /// Row id of a saved state of the system hosts file.
    static func historyRowID(_ id: String) -> String { "history:" + id }
    /// Row id of a trashed entry; trashed ids are no longer in the tree.
    static func trashRowID(_ id: String) -> String { "trash:" + id }

    var selectedHistory: ApplyRecord? {
        guard let id = selection, id.hasPrefix("history:") else { return nil }
        return historyRecords.first { Self.historyRowID($0.id) == id }
    }

    var selectedTrash: TrashItem? {
        guard let id = selection, id.hasPrefix("trash:") else { return nil }
        return trashItems.first { Self.trashRowID($0.id) == id }
    }

    /// A snapshot's name in the list: when it was saved.
    static func snapshotTitle(_ record: ApplyRecord) -> String {
        Format.relativeDate.string(from: record.date)
    }

    /// A click on a list row. ⌘ adds or removes the row from the selection and
    /// ⇧ selects a range, as in 5.0.2; only tree entries select together. A
    /// plain click on a folder row opens that folder's view.
    func clickRow(_ id: String, modifiers: NSEvent.ModifierFlags = []) {
        let entry = node(withID: id)
        let rows = listedRowIDs
        var ids: Set<String> = [id]
        var primary: String? = id
        if entry != nil, modifiers.contains(.command) {
            ids = selectedIDs.filter { node(withID: $0) != nil }
            if ids.contains(id) {
                ids.remove(id)
                primary = selection.flatMap { ids.contains($0) ? $0 : nil } ?? rows.first(where: ids.contains)
            } else {
                ids.insert(id)
            }
        } else if entry != nil, modifiers.contains(.shift),
                  let anchor = selection, let from = rows.firstIndex(of: anchor), let to = rows.firstIndex(of: id) {
            ids = Set(rows[min(from, to)...max(from, to)]).filter { node(withID: $0) != nil }
        } else if let entry, entry.isFolder {
            Task { await showSidebar(.folder(id)) }
            return
        }
        guard primary != selection else {
            selectedIDs = ids
            return
        }
        // The rows update at once, so the list keeps what was clicked; the
        // content loads after.
        let previous = selectedIDs
        selectedIDs = ids
        Task {
            await select(primary, rows: ids)
            if selection != primary {
                // The edits could not be saved and the user kept them.
                selectedIDs = previous
            }
        }
    }

    /// Moves the selection to the row above (-1) or below (+1).
    func moveSelection(by offset: Int) {
        let rows = listedRowIDs
        guard !rows.isEmpty else { return }
        let index = selection.flatMap(rows.firstIndex(of:)).map { $0 + offset } ?? (offset > 0 ? 0 : rows.count - 1)
        guard rows.indices.contains(index) else { return }
        let id = rows[index]
        Task { await select(id) }
    }

    // ---- selection and content --------------------------------------------

    /// Sidebar id for the read-only system hosts row.
    static let systemHostsID = "__system_hosts__"

    /// Whether the editor shows the read-only system hosts file.
    var isSystemHostsSelected: Bool { selection == Self.systemHostsID }

    /// Whether the selection is a folder (shown with its settings, not content).
    var isFolderSelected: Bool { selectedNode?.isFolder == true }

    /// Select a list row and load its text: an entry, the current system hosts
    /// file, a saved state of it, or a trashed entry. Folders and groups have no
    /// text of their own. `rows` is the whole selection when several entries
    /// are selected.
    func select(_ id: String?, rows: Set<String>? = nil) async {
        // The entry being left saves its edits first.
        guard await flushAutosave(askOnFailure: true) else { return }
        let load = beginContentLoad()
        selection = id
        selectedIDs = rows ?? (id.map { [$0] } ?? [])
        if id == Self.systemHostsID {
            await loadSystemHosts(load)
            return
        }
        if let record = selectedHistory {
            finishContentLoad(load, of: id, text: record.content)
            return
        }
        if let item = selectedTrash {
            let text = await trashContent(item)
            finishContentLoad(load, of: id, text: text)
            return
        }
        guard let id, let node = TreeDocument.find(id, in: await rawList())?.node else {
            finishContentLoad(load, of: id, text: "")
            return
        }
        // Folders and groups have no content of their own.
        if ["folder", "group"].contains(node["type"] as? String) {
            finishContentLoad(load, of: id, text: "")
            return
        }
        await loadContent(for: id, load: load)
    }

    /// Starts a content load. The editor's text then belongs to no entry
    /// until the load finishes, so it is not saved anywhere.
    private func beginContentLoad() -> Int {
        contentLoad += 1
        contentID = nil
        return contentLoad
    }

    /// Fills the editor with `text`, the content of `id`, unless a newer load
    /// started or the selection moved on meanwhile. Returns whether it did.
    @discardableResult
    private func finishContentLoad(_ load: Int, of id: String?, text: String) -> Bool {
        guard load == contentLoad, selection == id else { return false }
        content = text
        savedContent = text
        contentID = id
        return true
    }

    /// Empties the editor; its text then belongs to no entry.
    private func clearContent() {
        contentLoad += 1
        content = ""
        savedContent = ""
        contentID = nil
    }

    /// Reads the system hosts file through the core. Read-only in this view.
    func loadSystemHosts() async {
        await loadSystemHosts(beginContentLoad())
    }

    private func loadSystemHosts(_ load: Int) async {
        guard let core else { return }
        do {
            let text = try await core.call(String.self, "get_system_hosts")
            guard finishContentLoad(load, of: Self.systemHostsID, text: text) else { return }
            errorMessage = nil
        } catch {
            guard finishContentLoad(load, of: Self.systemHostsID, text: "") else { return }
            errorMessage = error.localizedDescription
        }
    }

    // ---- autosave -----------------------------------------------------------
    // As in the Tauri version, there is no Save button: a local entry is
    // written shortly after typing stops, and at once when the selection
    // changes, the window loses focus or closes, and before the app quits.

    /// Called by the editor once typing has paused. A pause that arrives after
    /// the editor moved on to other text is ignored.
    func editorPaused(with text: String) {
        guard text == content else { return }
        Task { await flushAutosave() }
    }

    /// Writes the selected local entry's unsaved edits now. Returns false only
    /// when the write failed and the user, asked because `askOnFailure` is
    /// set, chose to keep the edits rather than drop them. A failed write is
    /// shown in the error banner either way.
    @discardableResult
    func flushAutosave(askOnFailure: Bool = false) async -> Bool {
        // Only local entries are edited by hand; the rest are read-only, as in
        // 5.0.2. Text that is not the selected entry's own is never written to it.
        guard isDirty, let id = selection, id == contentID, selectedNode?.isLocal == true else { return true }
        if await writeContent(content, to: id) { return true }
        return askOnFailure ? confirmDiscardIfDirty() : true
    }

    /// Writes `text` as the content of `id`, after any save still running.
    private func writeContent(_ text: String, to id: String) async -> Bool {
        guard let core else { return false }
        let previous = lastSave
        let save = Task { () -> Bool in
            _ = await previous?.value
            do {
                try await core.send("set_hosts_content", [id, text])
                return true
            } catch {
                errorMessage = error.localizedDescription
                return false
            }
        }
        lastSave = save
        guard await save.value else { return false }
        // Typing may have gone on meanwhile; then the entry stays dirty and the
        // next pause saves the rest.
        if selection == id, contentID == id {
            savedContent = text
        }
        lineCounts[id] = Library.lineCount(of: text)
        // An enabled entry's new text goes to the system file, as in 5.0.2.
        reapplyChangedContent([id])
        return true
    }

    /// Loads the text of `id`, the selection, into the editor. A failed load
    /// leaves the editor empty rather than showing another entry's text.
    private func loadContent(for id: String, load: Int? = nil) async {
        guard let core else { return }
        let load = load ?? beginContentLoad()
        do {
            let text = try await core.call(String.self, "get_hosts_content", [id])
            if node(withID: id)?.isLocal == true {
                lineCounts[id] = Library.lineCount(of: text)
            }
            guard finishContentLoad(load, of: id, text: text) else { return }
            errorMessage = nil
        } catch {
            guard finishContentLoad(load, of: id, text: "") else { return }
            contentID = nil
            errorMessage = error.localizedDescription
        }
    }

    /// Asks before dropping edits that could not be saved. Returns false when
    /// the user keeps them.
    private func confirmDiscardIfDirty() -> Bool {
        guard isDirty else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Discard unsaved changes?")
        alert.informativeText = String(localized: "The edits to this entry could not be saved.")
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
            writeMode = mode
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

    /// The folder a new entry goes into; set when the entry sheet opens.
    private var newEntryParent: String?

    /// Opens the entry sheet for a new entry. It goes into the folder being
    /// viewed, or at the top level when `topLevel` is set or no folder is shown.
    func promptNew(_ kind: EntryKind, topLevel: Bool = false) {
        if !topLevel, case .folder(let id) = sidebar {
            newEntryParent = id
        } else {
            newEntryParent = nil
        }
        entryPrompt = .new(kind)
    }

    /// Creates an entry of any kind inside `newEntryParent`, or at the top
    /// level. A new remote entry is fetched straight away. The list then shows
    /// the new entry: a new folder opens its own view, and an entry the current
    /// view does not list switches to its folder or to all entries.
    func addEntry(_ draft: EntryDraft) async {
        let id = UUID().uuidString
        let parent = newEntryParent.flatMap { node(withID: $0)?.isFolder == true ? $0 : nil }
        newEntryParent = nil
        await editTree { list in
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
        guard node(withID: id) != nil else { return }
        if draft.kind == .folder {
            await showSidebar(.folder(id))
        } else if !listedRowIDs.contains(id) {
            setSidebar(parent.map { .folder($0) } ?? .all)
            listQuery = ""
        }
        if draft.kind == .remote, selection == id {
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

    /// Sets a folder's choice mode: 0 inherits the global mode, 1 single, 2 multiple.
    func setFolderMode(_ id: String, mode: Int) async {
        await editTree(selectingEdited: false) { list in
            guard TreeDocument.setFolderMode(id, mode: mode, in: &list) else {
                throw SwhError.command(String(localized: "The folder no longer exists."))
            }
            return id
        }
    }

    /// Moves an entry (and its children) into a folder, or to the top level when
    /// nil. Moving an entry to where it already is changes nothing.
    func move(_ id: String, toFolder parentID: String?, selecting: Bool = true) async {
        guard parentFolder(of: id)?.id != parentID || node(withID: id) == nil else { return }
        await editTree(selectingEdited: selecting) { list in
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
        // Save first, so a restored entry comes back with its latest text.
        await flushAutosave()
        do {
            if ids.count == 1 {
                try await core.send("move_to_trashcan", [ids[0]])
            } else {
                try await core.send("move_many_to_trashcan", [ids])
            }
            let next = selection.flatMap { ids.contains($0) ? nextRow(skipping: Set(ids)) : nil }
            if let current = selection, ids.contains(current) {
                selection = nil
                clearContent()
            }
            selectedIDs.subtract(ids)
            errorMessage = nil
            await reload()
            if let next, selection == nil, listedRowIDs.contains(next) {
                await select(next)
            }
        } catch {
            errorMessage = error.localizedDescription
            await reload()
        }
    }

    /// The first row after the selection that is not in `removed`, or else the
    /// last one before it.
    private func nextRow(skipping removed: Set<String>) -> String? {
        let rows = listedRowIDs
        guard let current = selection, let index = rows.firstIndex(of: current) else { return nil }
        return rows[(index + 1)...].first { !removed.contains($0) }
            ?? rows[..<index].last { !removed.contains($0) }
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
        // The core searches the saved text, so the editor's edits go first.
        await flushAutosave()
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
            if replaced {
                reapplyChangedContent([hit.itemId])
            }
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
        if !listedRowIDs.contains(item.itemId) {
            guard await flushAutosave(askOnFailure: true) else { return }
            setSidebar(.all)
            listQuery = ""
        }
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
            reapplyChangedContent(outcome.itemIds)
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
            clearLoadError()
            return Array(items.reversed())
        } catch {
            showLoadError(error)
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

    func loadHistory() async {
        historyRecords = await applyHistory()
        if let id = selection, id.hasPrefix("history:"), selectedHistory == nil {
            await select(Self.systemHostsID)
        }
    }

    /// Deletes a saved state after asking, then shows the next one.
    func deleteSnapshot(_ record: ApplyRecord) async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Delete Snapshot")
        alert.informativeText = String(localized: "Are you sure you want to delete this item?")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let next = rowAfter(Self.historyRowID(record.id))
        _ = await deleteApplyRecord(record.id)
        await loadHistory()
        await select(next.flatMap { listedRowIDs.contains($0) ? $0 : nil } ?? Self.systemHostsID)
    }

    /// Clears every saved state after asking.
    func confirmClearHistory() async {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Clear History")
        alert.informativeText = String(localized: "Clear all system hosts history? This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await clearApplyHistory()
        await loadHistory()
    }

    /// The row below `id` in the list, or the one above when it is the last.
    private func rowAfter(_ id: String) -> String? {
        let rows = listedRowIDs
        guard let index = rows.firstIndex(of: id) else { return nil }
        if index + 1 < rows.count { return rows[index + 1] }
        return index > 0 ? rows[index - 1] : nil
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
            // Moving enabled entries changes the order their records are
            // applied in, so the system file is written again, as in 5.0.2.
            if Self.enabledOrder(in: list) != Self.enabledOrder(in: before) {
                reapplyChangedContent(nil)
            }
            await reload()
            errorMessage = nil
            // Select through `select` so the editor shows the edited entry's
            // own content, not the previous entry's. A folder is a view, not a
            // row with content, so editing one leaves the selection alone.
            if selectingEdited, selection != touchedID, node(withID: touchedID)?.isFolder != true {
                await select(touchedID)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Ids of the switched-on nodes in tree order, the order their records are applied in.
    static func enabledOrder(in nodes: [TreeDocument.Node]) -> [String] {
        nodes.flatMap { node -> [String] in
            let own = node["on"] as? Bool == true ? [node["id"] as? String].compactMap { $0 } : []
            return own + enabledOrder(in: node["children"] as? [TreeDocument.Node] ?? [])
        }
    }

    /// The tree as untyped JSON. Empty when the core cannot be reached.
    private func rawList() async -> [TreeDocument.Node] {
        guard let core else { return [] }
        return (try? await core.json("get_list") as? [TreeDocument.Node]) ?? []
    }


    // ---- trashcan ----------------------------------------------------------

    func loadTrash() async {
        guard let core else { return }
        do {
            trashItems = try await core.call([TrashItem].self, "get_trashcan_list")
            clearLoadError()
        } catch {
            showLoadError(error)
        }
    }

    /// The content of a trashed entry, shown read-only. Folders and groups have none.
    func trashContent(_ item: TrashItem) async -> String {
        guard let core, item.data.isLocal || item.data.isRemote else { return "" }
        return (try? await core.call(String.self, "get_hosts_content", [item.id])) ?? ""
    }

    func restore(_ item: TrashItem) async {
        let next = rowAfter(Self.trashRowID(item.id))
        await trashAction("restore_item_from_trashcan", item.id)
        await selectTrashRow(next)
    }

    /// Deletes a trashed entry for good, after the same confirmation as 5.0.2.
    func deleteForever(_ item: TrashItem) async {
        guard confirmDelete(String(localized: "Do you want to delete this item completely?")) else { return }
        let next = rowAfter(Self.trashRowID(item.id))
        await trashAction("delete_item_from_trashcan", item.id)
        await selectTrashRow(next)
    }

    /// After a trashed entry leaves, selects `next` while the Trash view is shown.
    private func selectTrashRow(_ next: String?) async {
        guard sidebar == .trash else { return }
        await select(next.flatMap { listedRowIDs.contains($0) ? $0 : nil })
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
        if selectedTrash == nil, selection?.hasPrefix("trash:") == true {
            await select(nil)
        }
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

/// A view in the sidebar. Views only filter what the list shows; choosing one
/// writes nothing to the data. The window remembers the last one in UserDefaults.
enum SidebarItem: Hashable {
    /// The system hosts file and its saved states.
    case system
    /// Every entry that is not a folder.
    case all
    /// The entries that are on.
    case active
    case remote
    /// The entries directly inside a folder.
    case folder(String)
    case trash

    /// The value kept in UserDefaults.
    var storageValue: String {
        switch self {
        case .system: return "system"
        case .all: return "all"
        case .active: return "active"
        case .remote: return "remote"
        case .folder(let id): return "folder:" + id
        case .trash: return "trash"
        }
    }

    init?(storageValue: String) {
        switch storageValue {
        case "system": self = .system
        case "all": self = .all
        case "active": self = .active
        case "remote": self = .remote
        case "trash": self = .trash
        default:
            guard storageValue.hasPrefix("folder:"), storageValue.count > "folder:".count else { return nil }
            self = .folder(String(storageValue.dropFirst("folder:".count)))
        }
    }

    /// Whether the list shows tree entries, with their switches.
    var listsEntries: Bool {
        switch self {
        case .all, .active, .remote, .folder: return true
        case .system, .trash: return false
        }
    }

    /// Whether rows can be dragged into a new order in this view. The views
    /// that pick entries by state cannot be ordered; their entries can only be
    /// dragged to a folder in the sidebar.
    var allowsReordering: Bool {
        switch self {
        case .all, .folder: return true
        default: return false
        }
    }
}

/// What each sidebar view lists, and the counts beside them, worked out from
/// the tree as the core returns it.
enum Library {
    struct Counts: Equatable {
        /// Entries that are not folders.
        var all = 0
        /// Of those, the ones that are on.
        var active = 0
        var remote = 0
    }

    /// Every entry that is not a folder, in the tree's order (depth first).
    static func entries(in tree: [HostsNode]) -> [HostsNode] {
        tree.flatMap { node -> [HostsNode] in
            (node.isFolder ? [] : [node]) + entries(in: node.children ?? [])
        }
    }

    static func counts(in tree: [HostsNode]) -> Counts {
        let entries = entries(in: tree)
        return Counts(
            all: entries.count,
            active: entries.filter(\.isOn).count,
            remote: entries.filter(\.isRemote).count
        )
    }

    /// The rows of a view, before the search. Empty for views that do not list
    /// tree entries, and for a folder that no longer exists.
    static func rows(for item: SidebarItem, in tree: [HostsNode]) -> [HostsNode] {
        switch item {
        case .all: return entries(in: tree)
        case .active: return entries(in: tree).filter(\.isOn)
        case .remote: return entries(in: tree).filter(\.isRemote)
        case .folder(let id): return folder(id, in: tree)?.children ?? []
        case .system, .trash: return []
        }
    }

    /// Entries whose title contains `query`, ignoring case and accents. An
    /// empty query keeps them all.
    static func matching(_ nodes: [HostsNode], query: String) -> [HostsNode] {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return nodes }
        return nodes.filter { ($0.title ?? "").localizedStandardContains(query) }
    }

    /// Every folder, depth first, with its depth.
    static func folders(in tree: [HostsNode], depth: Int = 0) -> [FolderOption] {
        tree.flatMap { node -> [FolderOption] in
            guard node.isFolder else { return [] }
            return [FolderOption(id: node.id, title: node.title ?? node.id, depth: depth)]
                + folders(in: node.children ?? [], depth: depth + 1)
        }
    }

    /// The folder with `id`, at any depth.
    static func folder(_ id: String, in tree: [HostsNode]) -> HostsNode? {
        for node in tree {
            if node.id == id { return node.isFolder ? node : nil }
            if let found = folder(id, in: node.children ?? []) { return found }
        }
        return nil
    }

    /// The folder that directly holds `id`, or nil when it is at the top level
    /// or missing.
    static func parent(of id: String, in tree: [HostsNode]) -> HostsNode? {
        for node in tree {
            let children = node.children ?? []
            if children.contains(where: { $0.id == id }) { return node }
            if let found = parent(of: id, in: children) { return found }
        }
        return nil
    }

    /// Whether `id` is `ancestorID` itself or sits anywhere inside it. Nothing
    /// can move into its own subtree.
    static func isInSubtree(_ id: String, of ancestorID: String, in tree: [HostsNode]) -> Bool {
        guard id != ancestorID else { return true }
        func find(_ nodes: [HostsNode]) -> HostsNode? {
            for node in nodes {
                if node.id == ancestorID { return node }
                if let found = find(node.children ?? []) { return found }
            }
            return nil
        }
        guard let ancestor = find(tree) else { return false }
        return entries(in: ancestor.children ?? []).contains { $0.id == id }
            || folders(in: ancestor.children ?? []).contains { $0.id == id }
    }

    /// Lines as the editor's gutter numbers them: none for empty text, and a
    /// final newline starts one more.
    static func lineCount(of text: String) -> Int {
        text.isEmpty ? 0 : text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }
}
