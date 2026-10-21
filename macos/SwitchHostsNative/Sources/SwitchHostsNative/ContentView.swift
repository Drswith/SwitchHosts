import SwiftUI
import SwitchHostsCore
import UniformTypeIdentifiers

/// Main window, in three columns: the sidebar's views, the list of what the
/// chosen view holds, and the selected row in detail. Tree edits, switches,
/// the trashcan, and the system hosts history all go through the Rust core.
struct ContentView: View {
    @ObservedObject var model: HostsModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarColumn(model: model)
                .navigationSplitViewColumnWidth(min: 180, ideal: 212, max: 300)
        } content: {
            ListColumn(model: model)
                .navigationSplitViewColumnWidth(min: 250, ideal: 300, max: 440)
        } detail: {
            DetailColumn(model: model)
        }
        .frame(minWidth: 880, minHeight: 500)
        // The brand accent tints the window's switches, buttons, and links.
        .tint(.accent)
        .background(WindowFrameConfigurator(useSystemFrame: model.useSystemWindowFrame))
        // The sidebar's visibility is saved as the left panel preference, and the preference drives the sidebar.
        .onChange(of: columnVisibility) { visibility in
            model.setLeftPanel(shown: visibility == .all)
        }
        .onChange(of: model.leftPanelShown) { shown in
            let target: NavigationSplitViewVisibility = shown ? .all : .doubleColumn
            if columnVisibility != target {
                columnVisibility = target
            }
        }
        .sheet(item: $model.pendingImport) { pending in
            ImportSheet(
                pending: pending,
                onCommit: { mode in Task { await model.commitImport(mode: mode) } },
                onCancel: { Task { await model.cancelImport() } }
            )
        }
        .overlay(alignment: .bottom) {
            // Progress, the update notice, and errors float over the content.
            VStack(spacing: 8) {
                if let busy = model.busyMessage {
                    Banner(style: .progress, message: busy) { EmptyView() }
                }
                if let notice = model.updateNotice {
                    Banner(style: .notice, message: notice.message) {
                        Button("Open Release Page") { NSWorkspace.shared.open(notice.url) }
                            .controlSize(.small)
                        DismissButton { model.updateNotice = nil }
                    }
                }
                if let message = model.errorMessage {
                    Banner(style: .error, message: message) {
                        if model.retryImportURL != nil {
                            Button("Retry") {
                                Task { await model.retryURLImport() }
                            }
                            .controlSize(.small)
                        }
                        DismissButton { model.errorMessage = nil }
                    }
                }
            }
            .frame(maxWidth: 560)
            .padding(14)
            .animation(.easeOut(duration: 0.2), value: model.errorMessage)
            .animation(.easeOut(duration: 0.2), value: model.busyMessage)
        }
        .sheet(item: $model.entryPrompt) { prompt in
            EntrySheet(prompt: prompt, model: model)
        }
        .sheet(isPresented: $model.showFind) {
            FindSheet(model: model)
        }
        .sheet(isPresented: $model.showImportURL) {
            ImportURLSheet(model: model)
        }
        // Unsaved edits are written as soon as the window loses focus or closes.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            Task { await model.flushAutosave() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            Task { await model.flushAutosave() }
        }
        .task {
            // The model starts with the app; this only closes the window that
            // systems before macOS 15 open at launch despite "hide at launch".
            if AppBehavior.closesMainWindowAtLaunch {
                AppBehavior.closesMainWindowAtLaunch = false
                NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.close()
            }
        }
    }
}

// MARK: - Sidebar

/// The sidebar: the library's views, every folder (nested ones indented), and
/// the trash at the foot. The views only filter the list; choosing one writes
/// nothing. Entries dropped on a folder move into it, and on All Entries to
/// the top level.
private struct SidebarColumn: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        let counts = model.counts
        VStack(spacing: 0) {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                SidebarSectionTitle(title: "Library")
                SidebarRow(model: model, item: .system, symbol: "desktopcomputer", title: Text("System Hosts"))
                SidebarRow(model: model, item: .all, symbol: "square.stack.3d.up", title: Text("All Entries"), count: counts.all)
                SidebarRow(model: model, item: .active, symbol: "switch.2", title: Text("Enabled"), count: counts.active)
                SidebarRow(model: model, item: .remote, symbol: "globe", title: Text("Remote"), count: counts.remote)

                HStack(alignment: .lastTextBaseline) {
                    SidebarSectionTitle(title: "Folders")
                    Spacer()
                    Button {
                        model.promptNew(.folder, topLevel: true)
                    } label: {
                        Image(systemName: "folder.badge.plus")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("New Folder")
                    .padding(.trailing, 10)
                }
                ForEach(model.folderRows) { folder in
                    SidebarRow(
                        model: model,
                        item: .folder(folder.id),
                        symbol: "folder",
                        title: Text(verbatim: folder.title),
                        count: model.node(withID: folder.id)?.children?.count ?? 0,
                        indent: CGFloat(folder.depth) * 16
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
        // The trash stays at the foot, below the scrolling views.
        SidebarRow(model: model, item: .trash, symbol: "trash", title: Text("Trash"), count: model.trashItems.count)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
        }
    }
}

private struct SidebarSectionTitle: View {
    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, 10)
            .padding(.top, 10)
            .padding(.bottom, 2)
    }
}

/// One sidebar view: its icon, name, and count. The selected one has the soft
/// accent background.
private struct SidebarRow: View {
    @ObservedObject var model: HostsModel
    let item: SidebarItem
    let symbol: String
    let title: Text
    var count: Int?
    var indent: CGFloat = 0
    @State private var dropPlacement: TreeDocument.Placement?

    var body: some View {
        let selected = model.sidebar == item
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(selected ? Color.accentInk : Color.accent)
                .frame(width: 18)
            title
                .fontWeight(selected ? .medium : .regular)
                .foregroundStyle(selected ? Color.accentInk : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let count {
                Text(verbatim: "\(count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(selected ? Color.accentInk : Color.secondary)
            }
        }
        .padding(.leading, 10 + indent)
        .padding(.trailing, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentSoft : Color.clear))
        .overlay { DropIndicator(placement: dropPlacement, cornerRadius: 6) }
        .contentShape(Rectangle())
        .onTapGesture {
            Task { await model.showSidebar(item) }
        }
        .modifier(SidebarDragAndDrop(model: model, item: item, placement: $dropPlacement))
        .contextMenu { menu }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // VoiceOver and other assistive tools open the view the way a click does.
        .accessibilityAction { Task { await model.showSidebar(item) } }
    }

    @ViewBuilder private var menu: some View {
        switch item {
        case .folder(let id):
            if let node = model.node(withID: id) {
                EntryActions(model: model, node: node)
            }
        case .trash:
            Button("Empty Trash…") { Task { await model.clearTrash() } }
                .disabled(model.trashItems.isEmpty)
        case .system:
            Button("Clear History…") { Task { await model.confirmClearHistory() } }
        default:
            EmptyView()
        }
    }
}

/// Drags and drops on the sidebar. A folder can be dragged: onto another
/// folder's top or bottom quarter it goes before or after it, onto the middle
/// it goes inside. An entry dropped on a folder goes inside it, and on All
/// Entries to the top level. Moves into an entry's own subtree are refused.
private struct SidebarDragAndDrop: ViewModifier {
    let model: HostsModel
    let item: SidebarItem
    @Binding var placement: TreeDocument.Placement?

    func body(content: Content) -> some View {
        switch item {
        case .folder(let id):
            content
                .onDrag {
                    model.draggingID = id
                    return TreeDragPayload.provider(for: id)
                }
                .onDrop(of: [.plainText], delegate: TreeDropDelegate(
                    placement: $placement,
                    height: 28,
                    where: { y, height in
                        // Nothing goes into its own subtree.
                        guard model.canDrop(on: id) else { return nil }
                        // Entries always go in; folders can also go next to it.
                        guard model.node(withID: model.draggingID ?? "")?.isFolder == true else { return .inside }
                        if y < height * 0.25 { return .before }
                        if y > height * 0.75 { return .after }
                        return .inside
                    },
                    perform: { dragged, placement in
                        guard dragged != id else { return }
                        if placement == .inside {
                            await model.move(dragged, toFolder: id, selecting: false)
                        } else {
                            await model.drop(dragged, onto: id, placement: placement)
                        }
                    }
                ))
        case .all:
            content
                .onDrop(of: [.plainText], delegate: TreeDropDelegate(
                    placement: $placement,
                    height: 28,
                    where: { _, _ in .inside },
                    perform: { dragged, _ in await model.move(dragged, toFolder: nil, selecting: false) }
                ))
        default:
            content
        }
    }
}

// MARK: - List

/// The middle column: what the chosen view holds, under a search field. Its
/// title and subtitle head the column in the toolbar, with the New menu (and,
/// for a folder, its choice mode and switch) on the right.
private struct ListColumn: View {
    @ObservedObject var model: HostsModel
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.listQuery)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 2) {
                    rows
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
            .overlay { emptyState }
            .focusable()
            .focused($focused)
            .modifier(NoFocusRing())
            .onMoveCommand { direction in
                switch direction {
                case .up: model.moveSelection(by: -1)
                case .down: model.moveSelection(by: 1)
                default: break
                }
            }
            .onDeleteCommand { deleteSelection() }
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    @ViewBuilder private var rows: some View {
        switch model.sidebar {
        case .system:
            if model.listQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                PlainRow(
                    model: model,
                    id: HostsModel.systemHostsID,
                    symbol: "desktopcomputer",
                    title: Text("Current"),
                    subtitle: Text(verbatim: currentSubtitle)
                ) { focused = true }
            }
            ForEach(model.listedHistory) { record in
                PlainRow(
                    model: model,
                    id: HostsModel.historyRowID(record.id),
                    symbol: "clock.arrow.circlepath",
                    title: Text(verbatim: HostsModel.snapshotTitle(record)),
                    subtitle: Text(verbatim: Format.linesAndSize(record.content))
                ) { focused = true }
                .contextMenu {
                    Button("Delete Snapshot…") { Task { await model.deleteSnapshot(record) } }
                }
            }
        case .trash:
            ForEach(model.listedTrash) { item in
                PlainRow(
                    model: model,
                    id: HostsModel.trashRowID(item.id),
                    symbol: item.data.symbolName,
                    title: Text(verbatim: item.data.title ?? item.id),
                    subtitle: Text(verbatim: Format.kind(of: item.data) + " · " + Format.deleted(item))
                ) { focused = true }
                .contextMenu {
                    Button("Restore") { Task { await model.restore(item) } }
                    Button("Delete Permanently…") { Task { await model.deleteForever(item) } }
                }
            }
        default:
            let showsFolder = !isFolderView
            ForEach(model.listedEntries) { node in
                EntryRow(model: model, node: node, showsFolder: showsFolder) { focused = true }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if model.listedRowIDs.isEmpty {
            if !model.listQuery.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyState(symbol: "magnifyingglass", message: "No matches.")
            } else {
                switch model.sidebar {
                case .active: EmptyState(symbol: "switch.2", message: "No enabled entries")
                case .trash: EmptyState(symbol: "trash", message: "The trash is empty.")
                default: EmptyState(symbol: "tray", message: "No entries here yet")
                }
            }
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if case .folder(let id) = model.sidebar, let folder = model.node(withID: id) {
                FolderControls(model: model, folder: folder)
            }
            if model.sidebar.listsEntries {
                Menu {
                    NewEntryItems(model: model)
                } label: {
                    Label("New", systemImage: "plus")
                }
                .help("New")
            }
            if model.sidebar == .trash {
                Button {
                    Task { await model.clearTrash() }
                } label: {
                    Label("Empty Trash", systemImage: "trash.slash")
                }
                .help("Empty Trash")
                .disabled(model.trashItems.isEmpty)
            }
        }
    }

    private var isFolderView: Bool {
        if case .folder = model.sidebar { return true }
        return false
    }

    private var title: Text {
        switch model.sidebar {
        case .system: return Text("System Hosts")
        case .all: return Text("All Entries")
        case .active: return Text("Enabled")
        case .remote: return Text("Remote")
        case .folder(let id): return Text(verbatim: model.node(withID: id)?.title ?? "")
        case .trash: return Text("Trash")
        }
    }

    private var subtitle: Text {
        let counts = model.counts
        switch model.sidebar {
        case .system:
            return Text("Current file and ^[\(model.historyRecords.count) snapshot](inflect: true)")
        case .all:
            return Text("^[\(counts.all) entry](inflect: true) · \(counts.active) enabled")
        case .active:
            return Text("^[\(counts.active) entry](inflect: true)")
        case .remote:
            let enabled = Library.rows(for: .remote, in: model.tree).filter(\.isOn).count
            return Text("^[\(counts.remote) entry](inflect: true) · \(enabled) enabled")
        case .folder(let id):
            return Text("Folder · ^[\(model.node(withID: id)?.children?.count ?? 0) item](inflect: true)")
        case .trash:
            return Text("^[\(model.trashItems.count) item](inflect: true)")
        }
    }

    private var currentSubtitle: String {
        switch model.writeMode {
        case "append": return "/etc/hosts · " + String(localized: "Append")
        case "overwrite": return "/etc/hosts · " + String(localized: "Overwrite")
        default: return "/etc/hosts"
        }
    }

    /// The Delete key: entries go to the trash; a snapshot or a trashed entry
    /// is deleted for good, after asking.
    private func deleteSelection() {
        if let record = model.selectedHistory {
            Task { await model.deleteSnapshot(record) }
        } else if let item = model.selectedTrash {
            Task { await model.deleteForever(item) }
        } else if !model.trashableSelection.isEmpty {
            Task { await model.moveToTrash(ids: model.trashableSelection) }
        }
    }
}

/// The search field above the list. It filters the list by title.
private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
    }
}

/// One tree entry in the list: its icon, title, a second line with where it
/// sits and what it holds, and its switch. Selected rows are filled with the
/// accent. In All Entries and folder views a row takes drops on its top half
/// (before it) and bottom half (after it); every entry can be dragged to a
/// folder in the sidebar.
private struct EntryRow: View {
    @ObservedObject var model: HostsModel
    let node: HostsNode
    /// Whether the second line starts with the folder holding the entry.
    let showsFolder: Bool
    let onClick: () -> Void
    @State private var dropPlacement: TreeDocument.Placement?
    @State private var height: CGFloat = 48

    var body: some View {
        let selected = model.selectedIDs.contains(node.id)
        HStack(spacing: 10) {
            Image(systemName: node.symbolName)
                .font(.system(size: 15))
                .foregroundStyle(selected ? Color.white : Color.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: node.title ?? node.id)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: secondLine)
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            // Every entry has a switch, folders included: switching a folder
            // switches its children by the folder's choice mode (the core's rule).
            Toggle(
                node.title ?? node.id,
                isOn: Binding(
                    get: { node.isOn },
                    set: { _ in Task { await model.toggle(node) } }
                )
            )
            .labelsHidden()
            .toggleStyle(BrandSwitchStyle(onAccent: selected))
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accent : Color.clear))
        .overlay { DropIndicator(placement: dropPlacement, cornerRadius: 8) }
        .measureHeight($height)
        .contentShape(Rectangle())
        .onTapGesture {
            onClick()
            // The click being handled carries its own modifier keys.
            model.clickRow(node.id, modifiers: NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags)
        }
        .onDrag {
            model.draggingID = node.id
            return TreeDragPayload.provider(for: node.id)
        }
        .onDrop(of: [.plainText], delegate: TreeDropDelegate(
            placement: $dropPlacement,
            height: height,
            where: { y, height in
                // Views chosen by state cannot be put in order, and nothing goes
                // into its own subtree.
                guard model.sidebar.allowsReordering, model.canDrop(on: node.id) else { return nil }
                return y < height / 2 ? .before : .after
            },
            perform: { dragged, placement in
                guard dragged != node.id else { return }
                await model.drop(dragged, onto: node.id, placement: placement)
            }
        ))
        .contextMenu { EntryActions(model: model, node: node) }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction { model.clickRow(node.id) }
    }

    /// "[Folder · ]Local · 4 lines", "Remote · 15 minutes ago", "Group · Contains 2 entries".
    private var secondLine: String {
        var parts: [String] = []
        if showsFolder, let parent = model.parentFolder(of: node.id) {
            parts.append(parent.title ?? parent.id)
        }
        parts.append(Format.kind(of: node))
        if node.isLocal {
            parts.append(Format.lines(model.lineCount(of: node.id) ?? 0))
        } else if node.isRemote {
            parts.append(Format.ago(node.lastRefresh) ?? String(localized: "Not refreshed yet"))
        } else if node.isGroup {
            parts.append(Format.inflected("Contains ^[\(model.includedNodes(of: node).count) entry](inflect: true)"))
        } else if node.isFolder {
            parts.append(Format.inflected("^[\(node.children?.count ?? 0) item](inflect: true)"))
        }
        return parts.joined(separator: " · ")
    }
}

/// A list row with no switch: the current system hosts file, a saved state of
/// it, or a trashed entry.
private struct PlainRow: View {
    @ObservedObject var model: HostsModel
    let id: String
    let symbol: String
    let title: Text
    let subtitle: Text
    let onClick: () -> Void

    var body: some View {
        let selected = model.selection == id
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(selected ? Color.white : Color.accent)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                title
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                subtitle
                    .font(.system(size: 11))
                    .foregroundStyle(selected ? Color.white.opacity(0.8) : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.white : Color.primary)
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.accent : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            onClick()
            model.clickRow(id)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        // VoiceOver and other assistive tools select the row the way a click does.
        .accessibilityAction { model.clickRow(id) }
    }
}

/// The New menu's four kinds, as 5.0.2 offers them.
private struct NewEntryItems: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        Button("New Local Entry") { model.promptNew(.local) }
        Button("New Remote Entry") { model.promptNew(.remote) }
        Button("New Group") { model.promptNew(.group) }
        Button("New Folder") { model.promptNew(.folder) }
    }
}

/// What can be done to an entry, for its context menu and the More menu.
private struct EntryActions: View {
    @ObservedObject var model: HostsModel
    let node: HostsNode

    var body: some View {
        Button("Edit…") { model.entryPrompt = .edit(node) }
        if node.isRemote {
            Button("Refresh") { Task { await model.refreshRemote(node.id) } }
        }
        Divider()
        Button("Move Up") { Task { await model.move(node.id, by: -1) } }
        Button("Move Down") { Task { await model.move(node.id, by: 1) } }
        Menu("Move to Folder") {
            Button("Top Level") { Task { await model.move(node.id, toFolder: nil) } }
            Divider()
            ForEach(model.folderOptions(excluding: node.id)) { option in
                Button(String(repeating: "\u{00A0}\u{00A0}", count: option.depth) + option.title) {
                    Task { await model.move(node.id, toFolder: option.id) }
                }
            }
        }
        Divider()
        Button("Move to Trash") {
            Task { await model.moveToTrash(node.id) }
        }
    }
}

// MARK: - Drag and drop

/// Turns a drop on a row into a tree move. `where` decides from the pointer's
/// height in the row where the drop lands, or nil to refuse it; the row shows
/// that place while the pointer is over it.
private struct TreeDropDelegate: DropDelegate {
    @Binding var placement: TreeDocument.Placement?
    /// The row's height, to split it into zones.
    let height: CGFloat
    let `where`: (_ y: CGFloat, _ height: CGFloat) -> TreeDocument.Placement?
    let perform: @MainActor (_ dragged: String, _ placement: TreeDocument.Placement) async -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) {
        placement = `where`(info.location.y, height)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        placement = `where`(info.location.y, height)
        return DropProposal(operation: placement == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        placement = nil
    }

    /// The dragged id arrives with the drop, so nothing has to be remembered
    /// between the drag and the drop.
    func performDrop(info: DropInfo) -> Bool {
        defer { placement = nil }
        guard let target = `where`(info.location.y, height),
              let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let perform = perform
        Task { @MainActor in
            guard let dragged = await TreeDragPayload.id(from: provider) else { return }
            await perform(dragged, target)
        }
        return true
    }
}

/// Where a dragged entry will land: a line above or below the row, or an
/// outline around it when it goes inside.
private struct DropIndicator: View {
    let placement: TreeDocument.Placement?
    let cornerRadius: CGFloat

    var body: some View {
        switch placement {
        case .before:
            VStack {
                Capsule().fill(Color.accent).frame(height: 2)
                Spacer()
            }
            .offset(y: -2)
        case .after:
            VStack {
                Spacer()
                Capsule().fill(Color.accent).frame(height: 2)
            }
            .offset(y: 2)
        case .inside:
            RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.accent, lineWidth: 2)
        case nil:
            EmptyView()
        }
    }
}

private struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    /// Views around the measured one report the default; the largest is the row.
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private extension View {
    /// Keeps `height` equal to this view's height.
    func measureHeight(_ height: Binding<CGFloat>) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: HeightKey.self, value: proxy.size.height)
        })
        .onPreferenceChange(HeightKey.self) { height.wrappedValue = $0 }
    }
}

// MARK: - Detail

/// The right column: the selected row's title and tags, a strip saying where
/// read-only text comes from, and the text itself (or a group's entries).
private struct DetailColumn: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        Group {
            if model.isSystemHostsSelected {
                DetailBody(model: model, title: String(localized: "System Hosts"), readOnly: true) {
                    Tag("Read Only")
                    Tag(Text(verbatim: "/etc/hosts"))
                    Tag(Text(verbatim: Format.linesAndSize(model.content)), style: .bare)
                } strip: {
                    EmptyView()
                }
            } else if let record = model.selectedHistory {
                DetailBody(model: model, title: HostsModel.snapshotTitle(record), readOnly: true) {
                    Tag("Read Only")
                    Tag("Snapshot")
                    Tag(Text(verbatim: Format.linesAndSize(record.content)), style: .bare)
                } strip: {
                    SourceStrip(symbol: "clock.arrow.circlepath") {
                        // A sentence, not a path: it may wrap rather than be cut short.
                        Text("Saved when /etc/hosts was written. Read-only.")
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } trailing: {
                        Button("Delete Snapshot…") { Task { await model.deleteSnapshot(record) } }
                            .fontWeight(.semibold)
                    }
                }
            } else if let item = model.selectedTrash {
                if item.data.isLocal || item.data.isRemote {
                    DetailBody(model: model, title: item.data.title ?? item.id, readOnly: true) {
                        Tag(Text(verbatim: Format.kind(of: item.data)))
                        Tag("Deleted")
                        Tag(Text(verbatim: Format.linesAndSize(model.content)), style: .bare)
                    } strip: {
                        EmptyView()
                    }
                } else {
                    ContentListDetail(
                        title: item.data.title ?? item.id,
                        kind: Format.kind(of: item.data),
                        state: Text("Deleted"),
                        entries: item.data.isFolder ? (item.data.children ?? []) : model.includedNodes(of: item.data),
                        emptyMessage: item.data.isFolder ? "No entries yet." : "No entries included."
                    )
                }
            } else if let node = model.selectedNode, node.isGroup {
                // Read-only, as in 5.0.2: a group only lists other entries.
                ContentListDetail(
                    title: node.title ?? node.id,
                    kind: Format.kind(of: node),
                    state: node.isOn ? Text("Enabled") : Text("Disabled"),
                    isOn: node.isOn,
                    entries: model.includedNodes(of: node),
                    emptyMessage: "No entries included."
                ) {
                    Button("Edit…") { model.entryPrompt = .edit(node) }
                }
            } else if let node = model.selectedNode, !node.isFolder {
                DetailBody(model: model, title: node.title ?? node.id, readOnly: !node.isLocal) {
                    Tag(Text(verbatim: Format.kind(of: node)))
                    Tag(node.isOn ? Text("Enabled") : Text("Disabled"), style: node.isOn ? .enabled : .plain)
                    Tag(Text(verbatim: detailCount(node)), style: .bare)
                } strip: {
                    if node.isRemote {
                        RemoteStrip(model: model, node: node)
                    }
                }
            } else {
                EmptyState(symbol: "doc.text", message: "Select an entry to edit its content.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .toolbar { DetailToolbar(model: model) }
    }

    /// "10 lines · 216 B", and for a remote entry when it was last refreshed.
    private func detailCount(_ node: HostsNode) -> String {
        var text = Format.linesAndSize(model.content)
        if node.isRemote, let ago = Format.ago(node.lastRefresh) {
            text += " · " + String(localized: "Refreshed \(ago)")
        }
        return text
    }
}

/// A detail with text: the header, an optional strip, and the editor. Only
/// local entries can be edited; they save themselves shortly after typing stops.
private struct DetailBody<Tags: View, Strip: View>: View {
    @ObservedObject var model: HostsModel
    let title: String
    let readOnly: Bool
    @ViewBuilder var tags: () -> Tags
    @ViewBuilder var strip: () -> Strip

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneHeader(title: title) {
                HStack(spacing: 6) { tags() }
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 12)
            strip()
            if readOnly {
                HighlightingEditor(text: .constant(model.content), readOnly: true, reveal: model.reveal)
            } else {
                HighlightingEditor(text: $model.content, reveal: model.reveal, onPause: model.editorPaused)
            }
        }
    }
}

/// A detail that lists entries instead of text: a group's entries, or what a
/// trashed folder holds.
private struct ContentListDetail<Accessory: View>: View {
    let title: String
    let kind: String
    let state: Text
    var isOn = false
    let entries: [HostsNode]
    let emptyMessage: LocalizedStringKey
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(title: title) {
                    HStack(spacing: 6) {
                        Tag(Text(verbatim: kind))
                        Tag(state, style: isOn ? .enabled : .plain)
                        Spacer()
                        accessory()
                    }
                }
                GroupPane(entries: entries, emptyMessage: emptyMessage)
            }
            .padding(.horizontal, 28)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: 680, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension ContentListDetail where Accessory == EmptyView {
    init(title: String, kind: String, state: Text, isOn: Bool = false, entries: [HostsNode], emptyMessage: LocalizedStringKey) {
        self.init(title: title, kind: kind, state: state, isOn: isOn, entries: entries, emptyMessage: emptyMessage) {
            EmptyView()
        }
    }
}

/// The soft strip under the header of read-only text, saying where it comes from.
private struct SourceStrip<Leading: View, Trailing: View>: View {
    let symbol: String
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 13))
            leading()
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            trailing()
                .fixedSize()
        }
        .font(.system(size: 12))
        .foregroundStyle(Color.accentInk)
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.accentSoft, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }
}

/// Where a remote entry's text comes from, when it was fetched, and Refresh.
private struct RemoteStrip: View {
    @ObservedObject var model: HostsModel
    let node: HostsNode

    var body: some View {
        SourceStrip(symbol: node.source == "domain" ? "list.bullet" : "link") {
            Text(verbatim: source)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .layoutPriority(1)
        } trailing: {
            HStack(spacing: 10) {
                Text(verbatim: Format.ago(node.lastRefresh) ?? String(localized: "Not refreshed yet"))
                Button("Refresh") { Task { await model.refreshRemote(node.id) } }
                    .fontWeight(.semibold)
            }
        }
    }

    private var source: String {
        if node.source == "domain" {
            return (node.domains ?? []).joined(separator: ", ")
        }
        return node.url ?? ""
    }
}

/// The detail column's toolbar: Find, the backup menu, and More; for a trashed
/// entry, Delete Permanently and Restore instead. There is no Save button.
private struct DetailToolbar: ToolbarContent {
    @ObservedObject var model: HostsModel

    var body: some ToolbarContent {
        // The buttons sit at the right of the column.
        if #available(macOS 26.0, *) {
            ToolbarSpacer(.flexible)
        }
        if let item = model.selectedTrash {
            ToolbarItem {
                Button(role: .destructive) {
                    Task { await model.deleteForever(item) }
                } label: {
                    Text("Delete Permanently…")
                        .foregroundStyle(.red)
                }
                .help("Delete Permanently…")
            }
            // The main action, filled with the accent. On macOS 26 it sits on
            // its own glass; on the glass the toolbar's buttons share it would
            // be drawn as a plain button.
            if #available(macOS 26.0, *) {
                ToolbarItem {
                    Button("Restore") {
                        Task { await model.restore(item) }
                    }
                    .buttonStyle(.glassProminent)
                    .tint(.accent)
                    .help("Restore")
                }
                .sharedBackgroundVisibility(.hidden)
            } else {
                ToolbarItem {
                    Button("Restore") {
                        Task { await model.restore(item) }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.accent)
                    .help("Restore")
                }
            }
        } else {
            ToolbarItemGroup {
                Button {
                    model.showFind = true
                } label: {
                    Label("Find", systemImage: "magnifyingglass")
                }
                .help("Find and Replace")
                Menu {
                    Button("Import Backup…") { model.importBackupWithPanel() }
                    Button("Import from URL…") { model.showImportURL = true }
                    Divider()
                    Button("Export Backup…") { model.exportBackupWithPanel() }
                } label: {
                    Label("Backup", systemImage: "arrow.up.arrow.down")
                }
                .help("Backup")
                Menu {
                    moreItems
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More")
            }
        }
    }

    @ViewBuilder private var moreItems: some View {
        if let node = model.selectedNode, !node.isFolder {
            EntryActions(model: model, node: node)
        } else if let record = model.selectedHistory {
            Button("Delete Snapshot…") { Task { await model.deleteSnapshot(record) } }
            Button("Clear History…") { Task { await model.confirmClearHistory() } }
        } else if model.isSystemHostsSelected {
            Button("Clear History…") { Task { await model.confirmClearHistory() } }
                .disabled(model.historyRecords.isEmpty)
        } else {
            Button("Edit…") {}
                .disabled(true)
        }
    }
}

// MARK: - Sheets and window

/// Asks how to apply a staged backup: append it, replace the tree, or cancel.
private struct ImportSheet: View {
    let pending: HostsModel.PendingImport
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetLayout(title: Text("Import “\(pending.name)”"), width: 440) {
            Text("The backup has \(pending.count) top-level item(s). Append adds them to the current tree; Replace swaps the current tree for them.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } footer: {
            Button("Cancel") {
                onCancel()
                dismiss()
            }
            .keyboardShortcut(.cancelAction)
            Spacer()
            Button("Append") {
                onCommit("append")
                dismiss()
            }
            Button("Replace") {
                onCommit("replace")
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

/// Applies the window-frame preference. 5.0.2 defaults to a custom frame: the
/// content (the sidebar) runs up under the title bar, as the window has it by
/// default. The system frame keeps a standard title bar above the content.
/// Either way the title shows, since it heads the list column.
struct WindowFrameConfigurator: NSViewRepresentable {
    let useSystemFrame: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        DispatchQueue.main.async { apply(to: view.window, coordinator) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view.window, context.coordinator)
    }

    /// The window's own title bar settings, from before any change, so the
    /// custom frame can go back to them.
    final class Coordinator {
        var original: (transparent: Bool, fullSize: Bool)?
    }

    private func apply(to window: NSWindow?, _ coordinator: Coordinator) {
        guard let window else { return }
        let original = coordinator.original ?? (window.titlebarAppearsTransparent, window.styleMask.contains(.fullSizeContentView))
        coordinator.original = original
        window.titleVisibility = .visible
        if useSystemFrame {
            window.titlebarAppearsTransparent = false
            window.styleMask.remove(.fullSizeContentView)
        } else {
            window.titlebarAppearsTransparent = original.transparent
            if original.fullSize {
                window.styleMask.insert(.fullSizeContentView)
            }
        }
    }
}

/// macOS 14 and later can hide the ring a focused list draws; macOS 13 keeps it.
private struct NoFocusRing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 14.0, *) {
            content.focusEffectDisabled()
        } else {
            content
        }
    }
}

/// A small grey "Read Only" tag, as 5.0.2 shows it.
struct ReadOnlyBadge: View {
    var body: some View {
        Tag("Read Only")
    }
}

/// Short texts for list rows and tags.
enum Format {
    /// "Local", "Remote", "Group", or "Folder".
    static func kind(of node: HostsNode) -> String {
        if node.isFolder { return String(localized: "Folder") }
        if node.isRemote { return String(localized: "Remote") }
        if node.isGroup { return String(localized: "Group") }
        return String(localized: "Local")
    }

    /// "10 lines · 216 B".
    static func linesAndSize(_ text: String) -> String {
        lines(Library.lineCount(of: text)) + " · " + size(text.utf8.count)
    }

    /// "1 line", "10 lines".
    static func lines(_ count: Int) -> String {
        inflected("^[\(count) line](inflect: true)")
    }

    /// A localized text whose `^[…](inflect: true)` parts agree with their
    /// numbers ("1 item", "2 items").
    static func inflected(_ value: String.LocalizationValue) -> String {
        String(AttributedString(localized: value).characters)
    }

    /// Bytes as "216 B", "4.2 KB", or "1.3 MB".
    static func size(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024) }
        return String(format: "%.1f MB", Double(bytes) / 1024 / 1024)
    }

    /// "15 minutes ago" for a remote entry's last refresh, which the core
    /// writes as local time "yyyy-MM-dd HH:mm:ss". Other text is shown as it is.
    static func ago(_ lastRefresh: String?) -> String? {
        guard let lastRefresh, !lastRefresh.isEmpty else { return nil }
        guard let date = refreshParser.date(from: lastRefresh) else { return lastRefresh }
        return relative.localizedString(for: date, relativeTo: Date())
    }

    /// "Deleted Today 10:24" for a trashed entry.
    static func deleted(_ item: TrashItem) -> String {
        guard let ms = item.addTimeMs else { return String(localized: "Deleted") }
        let date = Date(timeIntervalSince1970: ms / 1000)
        return String(localized: "Deleted \(relativeDate.string(from: date))")
    }

    /// "Today 14:32", "Yesterday 09:05", or a date, as Finder shows times.
    static let relativeDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static let refreshParser: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

extension HostsNode {
    /// The SF Symbol for this kind of entry, after 5.0.2's item icons.
    var symbolName: String {
        if isFolder { return "folder" }
        if isRemote { return "globe" }
        if isGroup { return "square.stack" }
        return "doc.text"
    }
}
