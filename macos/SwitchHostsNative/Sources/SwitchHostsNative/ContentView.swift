import SwiftUI
import SwitchHostsCore
import UniformTypeIdentifiers

/// Main window: the hosts tree on the left, the selected entry's content on
/// the right. Tree edits and the trashcan go through the Rust core.
struct ContentView: View {
    @ObservedObject var model: HostsModel
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            List(selection: Binding(
                get: { model.selectedIDs },
                set: { ids in Task { await model.changeSelection(to: ids) } }
            )) {
                Label("System Hosts", systemImage: "desktopcomputer")
                    .tag(HostsModel.systemHostsID)
                TreeRows(nodes: model.tree, model: model)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: CGFloat(model.leftPanelWidth))
            .toolbar {
                ToolbarItemGroup {
                    Menu {
                        Button("New Local Entry") { model.entryPrompt = .new(.local) }
                        Button("New Remote Entry") { model.entryPrompt = .new(.remote) }
                        Button("New Group") { model.entryPrompt = .new(.group) }
                        Button("New Folder") { model.entryPrompt = .new(.folder) }
                    } label: {
                        Label("New", systemImage: "plus")
                    }
                    Button {
                        Task { await model.moveToTrash(ids: model.trashableSelection) }
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .disabled(model.trashableSelection.isEmpty)
                    Button {
                        Task {
                            await model.loadTrash()
                            model.showTrash = true
                        }
                    } label: {
                        Label("Trash", systemImage: "tray.full")
                    }
                    Button {
                        model.showFind = true
                    } label: {
                        Label("Find", systemImage: "magnifyingglass")
                    }
                    Button {
                        model.setRightPanel(shown: !model.rightPanelShown)
                    } label: {
                        Label("Info", systemImage: "sidebar.trailing")
                    }
                    Menu {
                        Button("Import Backup…") { model.importBackupWithPanel() }
                        Button("Import from URL…") { model.showImportURL = true }
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                    }
                    Button {
                        model.exportBackupWithPanel()
                    } label: {
                        Label("Export Backup", systemImage: "square.and.arrow.up")
                    }
                }
            }
        } detail: {
            HStack(spacing: 0) {
                EditorPane(model: model)
                if model.rightPanelShown {
                    Divider()
                    EntryInfoPanel(model: model)
                        .frame(width: CGFloat(model.rightPanelWidth))
                }
            }
        }
        .frame(minWidth: 760, minHeight: 460)
        .background(WindowFrameConfigurator(useSystemFrame: model.useSystemWindowFrame))
        // The sidebar's visibility is saved as the left panel preference, and the preference drives the sidebar.
        .onChange(of: columnVisibility) { visibility in
            model.setLeftPanel(shown: visibility != .detailOnly)
        }
        .onChange(of: model.leftPanelShown) { shown in
            let target: NavigationSplitViewVisibility = shown ? .all : .detailOnly
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
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                if let busy = model.busyMessage {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(busy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
                }
                if let notice = model.updateNotice {
                    HStack(spacing: 8) {
                        Text(notice.message)
                            .font(.callout)
                        Spacer()
                        Button("Open Release Page") { NSWorkspace.shared.open(notice.url) }
                        Button {
                            model.updateNotice = nil
                        } label: {
                            Image(systemName: "xmark")
                        }
                        .buttonStyle(.borderless)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
                }
                if let message = model.errorMessage {
                    HStack(spacing: 8) {
                        Text(message)
                            .font(.callout)
                            .foregroundStyle(.red)
                        Spacer()
                        if model.retryImportURL != nil {
                            Button("Retry") {
                                Task { await model.retryURLImport() }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.bar)
                }
            }
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
        .sheet(isPresented: $model.showHistory) {
            HistorySheet(model: model)
        }
        .sheet(isPresented: $model.showTrash) {
            TrashSheet(model: model)
        }
        .task {
            await model.start()
            if model.startsHidden {
                model.startsHidden = false
                NSApp.windows.first { $0.isVisible && $0.canBecomeMain }?.close()
            }
        }
    }
}


/// The hosts tree as sidebar rows. A folder is a disclosure group; its open
/// state is saved in the tree (`is_collapsed`), as the 5.0.2 sidebar does.
private struct TreeRows: View {
    let nodes: [HostsNode]
    @ObservedObject var model: HostsModel

    var body: some View {
        ForEach(nodes) { node in
            if node.isFolder {
                DisclosureGroup(isExpanded: expanded(node)) {
                    TreeRows(nodes: node.children ?? [], model: model)
                } label: {
                    DraggableRow(node: node, model: model) { row(node) }
                }
                .tag(node.id)
            } else {
                DraggableRow(node: node, model: model) { row(node) }
                    .tag(node.id)
            }
        }
    }

    private func row(_ node: HostsNode) -> EntryRow {
        EntryRow(node: node, model: model)
    }

    private func expanded(_ node: HostsNode) -> Binding<Bool> {
        Binding(
            get: { !node.isClosed },
            set: { open in Task { await model.setCollapsed(node.id, !open) } }
        )
    }
}

/// Makes a sidebar row draggable and a drop target. The top and bottom quarters
/// of a row drop before and after it; the middle of a folder drops into it.
private struct DraggableRow<Content: View>: View {
    let node: HostsNode
    @ObservedObject var model: HostsModel
    @ViewBuilder let content: () -> Content
    @State private var height: CGFloat = 24

    var body: some View {
        content()
            .background(GeometryReader { proxy in
                Color.clear.preference(key: RowHeightKey.self, value: proxy.size.height)
            })
            .onPreferenceChange(RowHeightKey.self) { height = $0 }
            .onDrag {
                TreeDragPayload.provider(for: node.id)
            }
            .onDrop(of: [.text], delegate: TreeDropDelegate(model: model, target: node, height: height))
    }
}

private struct RowHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 24

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Turns a drop on a row into a tree move. The drop position inside the row
/// decides the placement (see `placement`).
private struct TreeDropDelegate: DropDelegate {
    let model: HostsModel
    let target: HostsNode
    let height: CGFloat

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    /// The dragged id arrives with the drop, so nothing has to be remembered
    /// between the drag and the drop. Dropping an entry on itself does nothing.
    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [.plainText]).first else { return false }
        let placement = Self.placement(y: info.location.y, height: height, isFolder: target.isFolder)
        let targetID = target.id
        let model = model
        Task { @MainActor in
            guard let dragged = await TreeDragPayload.id(from: provider), dragged != targetID else { return }
            await model.drop(dragged, onto: targetID, placement: placement)
        }
        return true
    }

    static func placement(y: CGFloat, height: CGFloat, isFolder: Bool) -> TreeDocument.Placement {
        if y < height * 0.25 { return .before }
        if y > height * 0.75 { return .after }
        if isFolder { return .inside }
        return y < height / 2 ? .before : .after
    }
}

/// One row: title, folder marker, and the on/off switch.
private struct EntryRow: View {
    let node: HostsNode
    @ObservedObject var model: HostsModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: node.symbolName)
                .foregroundStyle(.secondary)
            Text(node.title ?? node.id)
                .fontWeight(node.isFolder ? .semibold : .regular)
            Spacer()
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
            .toggleStyle(.switch)
        }
        .contextMenu {
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
}

/// Content editor for the selected entry, with Save (⌘S) and an unsaved marker.
private struct EditorPane: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        Group {
            if model.selection == nil {
                Text("Select an entry to edit its content.")
                    .foregroundStyle(.secondary)
            } else if model.isSystemHostsSelected {
                // Read-only: the system file changes only through the apply path.
                HighlightingEditor(text: .constant(model.content), readOnly: true, reveal: model.reveal)
                    .padding(4)
                    .toolbar {
                        ToolbarItem {
                            Button {
                                model.showHistory = true
                            } label: {
                                Label("History", systemImage: "clock.arrow.circlepath")
                            }
                        }
                    }
            } else if let node = model.selectedNode, node.isFolder {
                FolderPane(model: model, node: node)
            } else if let node = model.selectedNode, node.isGroup {
                // Read-only, as in 5.0.2: a group only lists other entries.
                GroupPane(model: model, node: node)
            } else if let node = model.selectedNode, node.isRemote {
                // Read-only: the content is whatever the last refresh fetched.
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(remoteSource(node))
                            .font(.callout)
                            .textSelection(.enabled)
                        if let last = node.lastRefresh {
                            Text("Last refresh") + Text(": \(last)")
                        } else {
                            Text("Not refreshed yet")
                        }
                    }
                    .foregroundStyle(.secondary)
                    HighlightingEditor(text: .constant(model.content), readOnly: true, reveal: model.reveal)
                }
                .padding(8)
                .toolbar {
                    ToolbarItem {
                        Button("Refresh") {
                            Task { await model.refreshRemote(node.id) }
                        }
                    }
                }
            } else {
                HighlightingEditor(text: $model.content, reveal: model.reveal)
                    .padding(4)
                    .toolbar {
                        ToolbarItem {
                            Button("Save") {
                                Task { await model.saveContent() }
                            }
                            .keyboardShortcut("s", modifiers: .command)
                            .disabled(!model.isDirty)
                        }
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remoteSource(_ node: HostsNode) -> String {
        if node.source == "domain" {
            return (node.domains ?? []).joined(separator: ", ")
        }
        return node.url ?? ""
    }
}

/// Asks how to apply a staged backup: append it, replace the tree, or cancel.
private struct ImportSheet: View {
    let pending: HostsModel.PendingImport
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import “\(pending.name)”")
                .font(.headline)
            Text("The backup has \(pending.count) top-level item(s). Append adds them to the current tree; Replace swaps the current tree for them.")
                .foregroundStyle(.secondary)
            HStack {
                Button("Cancel") {
                    onCancel()
                    dismiss()
                }
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
        .padding(20)
        .frame(width: 420)
    }
}

/// Lists trashed entries with restore and delete actions. Selecting one shows
/// its content read-only, as 5.0.2 does for a trashcan item.
private struct TrashSheet: View {
    @ObservedObject var model: HostsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var preview = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trash").font(.headline)
            if model.trashItems.isEmpty {
                Text("The trash is empty.").foregroundStyle(.secondary)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    List(model.trashItems, selection: $selectedID) { item in
                        HStack {
                            Label(item.data.title ?? item.data.id, systemImage: item.data.symbolName)
                            Spacer()
                            Button("Restore") {
                                Task { await model.restore(item) }
                            }
                            Button("Delete") {
                                Task { await model.deleteForever(item) }
                            }
                        }
                        .tag(item.id)
                    }
                    .frame(width: 330, height: 260)
                    Group {
                        if selectedItem == nil {
                            Text("Select an item to see its content.")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        } else {
                            HighlightingEditor(text: .constant(preview), readOnly: true, reveal: nil)
                        }
                    }
                    .frame(width: 330, height: 260)
                    .border(Color.secondary.opacity(0.3))
                }
            }
            HStack {
                Button("Empty Trash") {
                    Task { await model.clearTrash() }
                }
                .disabled(model.trashItems.isEmpty)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 712)
        .task { await model.loadTrash() }
        .onChange(of: selectedID) { _ in
            Task { await loadPreview() }
        }
        .onChange(of: model.trashItems) { _ in
            if selectedItem == nil { selectedID = nil }
        }
    }

    private var selectedItem: TrashItem? {
        model.trashItems.first { $0.id == selectedID }
    }

    private func loadPreview() async {
        guard let item = selectedItem else {
            preview = ""
            return
        }
        preview = await model.trashContent(item)
    }
}

/// Applies the window-frame preference. 5.0.2 defaults to a custom frame: the
/// title text is hidden and the content runs under the title bar, while the
/// traffic lights and toolbar stay. The system frame keeps the standard title.
struct WindowFrameConfigurator: NSViewRepresentable {
    let useSystemFrame: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { apply(to: view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        apply(to: view.window)
    }

    private func apply(to window: NSWindow?) {
        guard let window else { return }
        if useSystemFrame {
            window.titleVisibility = .visible
            window.titlebarAppearsTransparent = false
            window.styleMask.remove(.fullSizeContentView)
        } else {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
        }
    }
}

/// Information about the selected entry: what it is, where its content comes
/// from, and how big it is. Shown on the right when "right panel" is on.
struct EntryInfoPanel: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Entry Info")
                .font(.headline)
            if model.isSystemHostsSelected {
                row("Name", "System Hosts")
                row("Type", LocalizedStringKey("System Hosts"))
                row("Path", "/etc/hosts")
            } else if let node = model.selectedNode {
                row("Name", node.title ?? node.id)
                row("Type", kindLabel(node))
                row("Status", LocalizedStringKey(node.isOn ? "Enabled" : "Disabled"))
                if node.isFolder {
                    row("Choice Mode", choiceLabel(node.folderMode ?? 0))
                    row("Entries", "\((node.children ?? []).count)")
                }
                if node.isGroup {
                    let titles = model.includedNodes(of: node).map { $0.title ?? $0.id }
                    row("Content", titles.isEmpty ? "—" : titles.joined(separator: "\n"))
                }
                if node.isRemote {
                    row("Source", LocalizedStringKey(node.source == "domain" ? "Domains" : "URL"))
                    row("Address", node.source == "domain" ? (node.domains ?? []).joined(separator: ", ") : (node.url ?? ""))
                    row("Refresh interval", RefreshInterval.label(node.refreshInterval ?? 0))
                    row("Last refresh", node.lastRefresh ?? "—")
                }
                if node.isLocal || node.isRemote {
                    let text = model.content
                    row("Size", ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))
                    row("Lines", "\(text.split(separator: "\n", omittingEmptySubsequences: false).count)")
                }
            } else {
                Text("Select an entry to see its details.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxHeight: .infinity, alignment: .topLeading)
    }

    private func row(_ title: LocalizedStringKey, _ value: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled)
        }
    }

    private func kindLabel(_ node: HostsNode) -> LocalizedStringKey {
        if node.isFolder { return "Folder" }
        if node.isRemote { return "Remote Entry" }
        if node.isGroup { return "Group" }
        return "Local"
    }

    private func choiceLabel(_ mode: Int) -> LocalizedStringKey {
        switch mode {
        case 1: return "Single"
        case 2: return "Multiple"
        default: return "Default"
        }
    }
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

