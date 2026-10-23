import SwiftUI
import SwitchHostsCore

/// The four kinds of entry 5.0.2 can create.
enum EntryKind: String, CaseIterable, Identifiable {
    case local
    case remote
    case group
    case folder

    var id: String { rawValue }

    init(_ node: HostsNode) {
        if node.isRemote {
            self = .remote
        } else if node.isGroup {
            self = .group
        } else if node.isFolder {
            self = .folder
        } else {
            self = .local
        }
    }

    var label: LocalizedStringKey {
        switch self {
        case .local: return "Local"
        case .remote: return "Remote"
        case .group: return "Group"
        case .folder: return "Folder"
        }
    }

    var symbolName: String {
        switch self {
        case .local: return "doc.text"
        case .remote: return "globe"
        case .group: return "square.stack"
        case .folder: return "folder"
        }
    }
}

/// Which entry the sheet is creating or editing.
enum EntryPrompt: Identifiable {
    case new(EntryKind)
    case edit(HostsNode)

    var id: String {
        switch self {
        case .new(let kind): return "new-\(kind.rawValue)"
        case .edit(let node): return "edit-\(node.id)"
        }
    }
}

/// What the sheet saves. Only the fields of `kind` are used.
struct EntryDraft: Equatable {
    var kind: EntryKind
    var title: String
    /// Remote: one address, or a list of domains.
    var url: String?
    var domains: [String]?
    var refreshInterval: Int
    /// Group: the local and remote entries it lists, in the order chosen.
    var include: [String]
    /// Folder: 0 inherits the global choice mode, 1 single, 2 multiple.
    var folderMode: Int
}

/// Refresh intervals for remote entries, as 5.0.2 offers them.
enum RefreshInterval {
    static let options = [0, 60, 300, 900, 3600, 86400, 604800]

    /// "Never", "5 minutes", "1 day", and so on, after 5.0.2's `formatInterval`.
    static func label(_ seconds: Int) -> String {
        if seconds <= 0 { return String(localized: "Never") }
        if seconds < 60 { return "\(seconds) s" }
        let minutes = Int((Double(seconds) / 60).rounded())
        if minutes < 60 {
            return "\(minutes) " + (minutes == 1 ? String(localized: "minute") : String(localized: "minutes"))
        }
        let hours = Int((Double(minutes) / 60).rounded())
        if hours < 24 {
            return "\(hours) " + (hours == 1 ? String(localized: "hour") : String(localized: "hours"))
        }
        let days = Int((Double(hours) / 24).rounded())
        return "\(days) " + (days == 1 ? String(localized: "day") : String(localized: "days"))
    }
}

/// Create or edit an entry, after 5.0.2's edit drawer: the type as four
/// tiles (fixed once created), then a grouped form with the title and the
/// fields of that type.
struct EntrySheet: View {
    let prompt: EntryPrompt
    @ObservedObject var model: HostsModel
    @Environment(\.dismiss) private var dismiss

    @State private var kind: EntryKind = .local
    @State private var title = ""
    @State private var usesDomains = false
    @State private var address = ""
    @State private var domainText = ""
    @State private var interval = 0
    @State private var include: [String] = []
    @State private var folderMode = 0

    var body: some View {
        SheetLayout(title: Text(isNew ? LocalizedStringKey("Add Hosts Entry") : LocalizedStringKey("Edit Hosts")),
            width: 520
        ) {
            HStack(spacing: 8) {
                ForEach(EntryKind.allCases) { option in
                    KindTile(kind: option, selected: option == kind) {
                        kind = option
                    }
                    // The kind is fixed once the entry exists, as in 5.0.2.
                    .disabled(!isNew && option != kind)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("Hosts Type"))
            FormGroup {
                row("Hosts Title") {
                    TextField("Hosts Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .labelsHidden()
                        .onSubmit(submit)
                }
                switch kind {
                case .local:
                    EmptyView()
                case .remote:
                    remoteFields
                case .group:
                    groupFields
                case .folder:
                    folderFields
                }
            }
        } footer: {
            if case .edit(let node) = prompt {
                Button("Move to Trash") {
                    dismiss()
                    // Only the entry being edited, not the other selected rows.
                    Task { await model.moveToTrash(ids: [node.id]) }
                }
                .foregroundStyle(.red)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? LocalizedStringKey("Create") : LocalizedStringKey("Save"), action: submit)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
        }
        .onAppear(perform: load)
    }

    // ---- fields by type ------------------------------------------------------

    @ViewBuilder private var remoteFields: some View {
        Divider()
        row("Source") {
            Picker("Source", selection: $usesDomains) {
                Text("URL").tag(false)
                Text("Domains").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        Divider()
        if usesDomains {
            row("Domains", alignment: .top) {
                TextEditor(text: $domainText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 96)
                    .overlay(alignment: .topLeading) {
                        if domainText.isEmpty {
                            Text("One domain per line").foregroundStyle(.secondary).padding(6)
                        }
                    }
            }
        } else {
            row("URL") {
                TextField("http:// or https:// or file://", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .labelsHidden()
                    .onSubmit(submit)
            }
        }
        Divider()
        row("Auto Refresh") {
            Picker("Auto Refresh", selection: $interval) {
                ForEach(intervalOptions, id: \.self) { seconds in
                    Text(verbatim: RefreshInterval.label(seconds)).tag(seconds)
                }
            }
            .labelsHidden()
            .fixedSize()
        }
        if case .edit(let node) = prompt {
            Divider()
            row("Last refresh") {
                HStack(spacing: 8) {
                    Text(verbatim: model.node(withID: node.id)?.lastRefresh ?? "N/A")
                        .foregroundStyle(.secondary)
                    Button("Refresh") {
                        Task { await model.refreshRemote(node.id) }
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    /// The local and remote entries a group can list, each with a checkbox.
    @ViewBuilder private var groupFields: some View {
        Divider()
        row("Content", alignment: .top) {
            let candidates = model.allNodes.filter { $0.isLocal || $0.isRemote }
            if candidates.isEmpty {
                Text("No local or remote entries yet.")
                    .foregroundStyle(.secondary)
            } else {
                List(candidates) { node in
                    Toggle(isOn: includes(node.id)) {
                        Label(node.title ?? node.id, systemImage: node.symbolName)
                    }
                    .toggleStyle(.checkbox)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                // Short enough that the sheet fits the window at its minimum height.
                .frame(height: 140)
            }
        }
    }

    @ViewBuilder private var folderFields: some View {
        Divider()
        row("Choice Mode", alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Choice Mode", selection: $folderMode) {
                    Text("Default").tag(0)
                    Text("Single").tag(1)
                    Text("Multiple").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Text(FolderControls.effect(of: folderMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// One row of the grouped form: the label in a fixed column, then the control.
    private func row<Content: View>(
        _ label: LocalizedStringKey,
        alignment: VerticalAlignment = .center,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: alignment, spacing: 12) {
            Text(label)
                .frame(width: 92, alignment: .leading)
                .padding(.top, alignment == .top ? 4 : 0)
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func includes(_ id: String) -> Binding<Bool> {
        Binding(
            get: { include.contains(id) },
            set: { on in
                if on {
                    if !include.contains(id) { include.append(id) }
                } else {
                    include.removeAll { $0 == id }
                }
            }
        )
    }

    // ---- state -----------------------------------------------------------------

    private var isNew: Bool {
        if case .new = prompt { return true }
        return false
    }

    /// The standard options, plus the entry's own interval when it is not one of them.
    private var intervalOptions: [Int] {
        RefreshInterval.options.contains(interval) ? RefreshInterval.options : (RefreshInterval.options + [interval]).sorted()
    }

    private var domains: [String] {
        domainText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private var canSave: Bool {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if kind == .remote {
            return usesDomains ? !domains.isEmpty : !address.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return true
    }

    private func load() {
        switch prompt {
        case .new(let kind):
            self.kind = kind
        case .edit(let node):
            kind = EntryKind(node)
            title = node.title ?? ""
            usesDomains = node.source == "domain"
            address = node.url ?? ""
            domainText = (node.domains ?? []).joined(separator: "\n")
            interval = node.refreshInterval ?? 0
            include = node.include ?? []
            folderMode = node.folderMode ?? 0
        }
    }

    private func submit() {
        guard canSave else { return }
        let draft = EntryDraft(
            kind: kind,
            title: title.trimmingCharacters(in: .whitespaces),
            url: usesDomains ? nil : address.trimmingCharacters(in: .whitespaces),
            domains: usesDomains ? domains : nil,
            refreshInterval: interval,
            include: include,
            folderMode: folderMode
        )
        dismiss()
        Task {
            switch prompt {
            case .new:
                await model.addEntry(draft)
            case .edit(let node):
                await model.updateEntry(node.id, draft)
            }
        }
    }
}

/// One of the four kinds as a tile at the top of the entry sheet. The chosen
/// one has the soft accent background and an accent ring.
private struct KindTile: View {
    let kind: EntryKind
    let selected: Bool
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 18))
                Text(kind.label)
                    .font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .foregroundStyle(selected ? Color.accentInk : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.accentSoft : Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(selected ? Color.accent : Color.clear, lineWidth: 1.5)
            )
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Rows of a form on one rounded background, as a grouped form shows them.
private struct FormGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content()
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}
