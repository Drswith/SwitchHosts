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
                set: { ids in model.changeSelection(to: ids) }
            )) {
                // Sidebar labels tint their icons, and turn them white on the selected row.
                Label("System Hosts", systemImage: "desktopcomputer")
                    .tag(HostsModel.systemHostsID)
                TreeRows(nodes: model.tree, model: model)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 220, ideal: CGFloat(model.leftPanelWidth))
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SidebarFooter(model: model)
            }
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
                    .help("New")
                    Button {
                        Task { await model.moveToTrash(ids: model.trashableSelection) }
                    } label: {
                        Label("Move to Trash", systemImage: "trash")
                    }
                    .help("Move to Trash")
                    .disabled(model.trashableSelection.isEmpty)
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
            .toolbar {
                // On the left, next to the sidebar button, so it never crowds the
                // buttons on the right.
                ToolbarItem(placement: .navigation) {
                    CurrentEntryTitle(model: model)
                }
                ToolbarItemGroup(placement: .primaryAction) {
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
                    Button {
                        model.setRightPanel(shown: !model.rightPanelShown)
                    } label: {
                        Label("Info", systemImage: "sidebar.trailing")
                    }
                    .help("Entry Info")
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

/// The foot of the sidebar: the trashcan, with how many entries it holds, as
/// 5.0.2 keeps it at the bottom of its left panel.
private struct SidebarFooter: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button {
                Task {
                    await model.loadTrash()
                    model.showTrash = true
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash")
                        .frame(width: 19)
                    Text("Trash")
                    Spacer()
                    if !model.trashItems.isEmpty {
                        Text(verbatim: "\(model.trashItems.count)")
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.18)))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
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
            // `itemProvider` is the drag hook for List rows: unlike `onDrag`, it
            // leaves a plain click to the list, so the row still gets selected.
            .itemProvider {
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

/// One row: the kind's icon, the title, and the on/off switch.
private struct EntryRow: View {
    let node: HostsNode
    @ObservedObject var model: HostsModel

    var body: some View {
        HStack(spacing: 6) {
            Label {
                Text(node.title ?? node.id)
                    .fontWeight(node.isFolder ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } icon: {
                Image(systemName: node.symbolName)
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
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .padding(.vertical, 1)
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

/// Content editor for the selected entry, with Save (⌘S). Read-only kinds get a
/// strip above the text saying where it comes from.
private struct EditorPane: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        Group {
            if model.selection == nil {
                EmptyState(symbol: "sidebar.left", message: "Select an entry to edit its content.")
            } else if model.isSystemHostsSelected {
                // Read-only: the system file changes only through the apply path.
                VStack(spacing: 0) {
                    EditorStrip(symbol: "lock", text: "/etc/hosts") { EmptyView() }
                    Divider()
                    HighlightingEditor(text: .constant(model.content), readOnly: true, reveal: model.reveal)
                }
                .toolbar {
                    ToolbarItem {
                        Button {
                            model.showHistory = true
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .help("History")
                    }
                }
            } else if let node = model.selectedNode, node.isFolder {
                FolderPane(model: model, node: node)
            } else if let node = model.selectedNode, node.isGroup {
                // Read-only, as in 5.0.2: a group only lists other entries.
                GroupPane(model: model, node: node)
            } else if let node = model.selectedNode, node.isRemote {
                // Read-only: the content is whatever the last refresh fetched.
                VStack(spacing: 0) {
                    EditorStrip(symbol: node.source == "domain" ? "list.bullet" : "link", text: remoteSource(node)) {
                        if let last = node.lastRefresh {
                            Text("Last refresh") + Text(verbatim: ": \(last)")
                        } else {
                            Text("Not refreshed yet")
                        }
                    }
                    Divider()
                    HighlightingEditor(text: .constant(model.content), readOnly: true, reveal: model.reveal)
                }
                .toolbar {
                    ToolbarItem {
                        Button {
                            Task { await model.refreshRemote(node.id) }
                        } label: {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                        .help("Refresh")
                    }
                }
            } else {
                HighlightingEditor(text: $model.content, reveal: model.reveal)
                    .toolbar {
                        ToolbarItem {
                            Button {
                                Task { await model.saveContent() }
                            } label: {
                                Label("Save", systemImage: "square.and.arrow.down")
                            }
                            .help("Save")
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

/// A thin strip above a read-only editor: where the text comes from, and a note
/// on the right.
private struct EditorStrip<Detail: View>: View {
    let symbol: String
    let text: String
    @ViewBuilder var detail: () -> Detail

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
            Text(verbatim: text)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer(minLength: 12)
            // The note keeps its full width; the source truncates instead.
            detail()
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

/// Asks how to apply a staged backup: append it, replace the tree, or cancel.
private struct ImportSheet: View {
    let pending: HostsModel.PendingImport
    let onCommit: (String) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SheetLayout(symbol: "square.and.arrow.down", title: Text("Import “\(pending.name)”"), width: 440) {
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

/// Lists trashed entries with restore and delete actions. Selecting one shows
/// its content read-only, as 5.0.2 does for a trashcan item.
private struct TrashSheet: View {
    @ObservedObject var model: HostsModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var preview = ""

    var body: some View {
        SheetLayout(symbol: "trash", title: Text("Trash"), width: 760) {
            if model.trashItems.isEmpty {
                EmptyState(symbol: "trash", message: "The trash is empty.")
                    .frame(height: 260)
            } else {
                HStack(alignment: .top, spacing: 12) {
                    List(model.trashItems, selection: $selectedID) { item in
                        HStack(spacing: 8) {
                            Label(item.data.title ?? item.data.id, systemImage: item.data.symbolName)
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Button("Restore") {
                                Task { await model.restore(item) }
                            }
                            .controlSize(.small)
                            Button("Delete") {
                                Task { await model.deleteForever(item) }
                            }
                            .controlSize(.small)
                        }
                        .padding(.vertical, 2)
                        .tag(item.id)
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: true))
                    .frame(width: 350, height: 280)
                    Group {
                        if selectedItem == nil {
                            EmptyState(symbol: "doc.text.magnifyingglass", message: "Select an item to see its content.")
                        } else {
                            HighlightingEditor(text: .constant(preview), readOnly: true, reveal: nil)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
                }
            }
        } footer: {
            Button("Empty Trash") {
                Task { await model.clearTrash() }
            }
            .disabled(model.trashItems.isEmpty)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Entry Info")
                    .font(.headline)
                if model.isSystemHostsSelected {
                    header(symbol: "desktopcomputer", title: String(localized: "System Hosts"), kind: "System Hosts")
                    Card {
                        row("Status") { Text("Read Only") }
                        row("Path") { Text(verbatim: "/etc/hosts") }
                    }
                } else if let node = model.selectedNode {
                    header(symbol: node.symbolName, title: node.title ?? node.id, kind: kindLabel(node))
                    Card {
                        row("Status") { StatusDot(isOn: node.isOn) }
                        if node.isFolder {
                            row("Choice Mode") { Text(choiceLabel(node.folderMode ?? 0)) }
                            row("Entries") { Text(verbatim: "\((node.children ?? []).count)") }
                        }
                        if node.isGroup {
                            row("Content") {
                                let included = model.includedNodes(of: node)
                                if included.isEmpty {
                                    Text(verbatim: "—")
                                } else {
                                    VStack(alignment: .leading, spacing: 3) {
                                        ForEach(included) { entry in
                                            Label(entry.title ?? entry.id, systemImage: entry.symbolName)
                                        }
                                    }
                                }
                            }
                        }
                        if node.isRemote {
                            row("Source") { Text(LocalizedStringKey(node.source == "domain" ? "Domains" : "URL")) }
                            row("Address") {
                                Text(verbatim: node.source == "domain" ? (node.domains ?? []).joined(separator: ", ") : (node.url ?? ""))
                            }
                            row("Refresh interval") { Text(verbatim: RefreshInterval.label(node.refreshInterval ?? 0)) }
                            row("Last refresh") { Text(verbatim: node.lastRefresh ?? "—") }
                        }
                    }
                    if node.isLocal || node.isRemote {
                        let text = model.content
                        Card {
                            row("Size") {
                                Text(verbatim: ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file))
                            }
                            row("Lines") {
                                Text(verbatim: "\(text.split(separator: "\n", omittingEmptySubsequences: false).count)")
                            }
                        }
                    }
                } else {
                    EmptyState(symbol: "info.circle", message: "Select an entry to see its details.")
                        .frame(height: 220)
                }
            }
            .padding(14)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func header(symbol: String, title: String, kind: LocalizedStringKey) -> some View {
        HStack(spacing: 10) {
            KindIcon(symbol: symbol, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Text(kind)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row<Value: View>(_ title: LocalizedStringKey, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            value()
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

/// The selected entry in the toolbar, as 5.0.2's top bar shows it: its icon and
/// title, a "Read Only" badge for anything not edited by hand, and its switch
/// while the sidebar (which has the switches) is hidden.
private struct CurrentEntryTitle: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        HStack(spacing: 8) {
            if model.isSystemHostsSelected {
                Image(systemName: "desktopcomputer")
                Text("System Hosts").fontWeight(.semibold)
                ReadOnlyBadge()
            } else if let node = model.selectedNode {
                Image(systemName: node.symbolName)
                Text(node.title ?? node.id)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !node.isLocal {
                    ReadOnlyBadge()
                } else if model.isDirty {
                    Text("Unsaved")
                        .font(.caption2)
                        .padding(.horizontal, 4)
                        .background(Color.orange.opacity(0.18), in: RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(.orange)
                }
                if !model.leftPanelShown {
                    Toggle(
                        node.title ?? node.id,
                        isOn: Binding(
                            get: { node.isOn },
                            set: { _ in Task { await model.toggle(node) } }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }
        }
    }
}

/// A small grey "Read Only" tag, as 5.0.2 shows it.
struct ReadOnlyBadge: View {
    var body: some View {
        Text("Read Only")
            .font(.caption2)
            .padding(.horizontal, 4)
            .background(Color.secondary.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            .foregroundStyle(.secondary)
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

