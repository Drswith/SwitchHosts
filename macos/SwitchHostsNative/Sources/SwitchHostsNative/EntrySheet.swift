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

/// Create or edit an entry, after 5.0.2's edit drawer: the type (fixed once
/// created), the title, and the fields of that type.
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
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? LocalizedStringKey("Add Hosts Entry") : LocalizedStringKey("Edit Hosts"))
                .font(.headline)

            field("Hosts Type") {
                Picker("Hosts Type", selection: $kind) {
                    ForEach(EntryKind.allCases) { kind in
                        Label(kind.label, systemImage: kind.symbolName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(!isNew)
            }

            field("Hosts Title") {
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

            HStack {
                if case .edit(let node) = prompt {
                    Button("Move to Trash") {
                        dismiss()
                        Task { await model.moveToTrash(node.id) }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("OK", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: load)
    }

    // ---- fields by type ------------------------------------------------------

    private var remoteFields: some View {
        VStack(alignment: .leading, spacing: 14) {
            field("Source") {
                Picker("Source", selection: $usesDomains) {
                    Text("URL").tag(false)
                    Text("Domains").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if usesDomains {
                TextEditor(text: $domainText)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 110)
                    .overlay(alignment: .topLeading) {
                        if domainText.isEmpty {
                            Text("One domain per line").foregroundStyle(.secondary).padding(6)
                        }
                    }
            } else {
                TextField("http:// or https:// or file://", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
            }
            field("Auto Refresh") {
                Picker("Auto Refresh", selection: $interval) {
                    ForEach(intervalOptions, id: \.self) { seconds in
                        Text(verbatim: RefreshInterval.label(seconds)).tag(seconds)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            if case .edit(let node) = prompt {
                HStack(spacing: 8) {
                    Text("Last refresh") + Text(verbatim: ": \(model.node(withID: node.id)?.lastRefresh ?? "N/A")")
                    Button("Refresh") {
                        Task { await model.refreshRemote(node.id) }
                    }
                    .buttonStyle(.borderless)
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
        }
    }

    /// The local and remote entries a group can list, each with a checkbox.
    private var groupFields: some View {
        field("Content") {
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
                // Short enough that the sheet fits the window at its minimum height.
                .frame(height: 150)
            }
        }
    }

    private var folderFields: some View {
        field("Choice Mode") {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Choice Mode", selection: $folderMode) {
                    Text("Default").tag(0)
                    Text("Single").tag(1)
                    Text("Multiple").tag(2)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 360)
                Text(FolderPane.effect(of: folderMode))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func field<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(.secondary)
            content()
        }
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
