import SwiftUI
import SwitchHostsCore

/// What a remote entry is set to fetch. Either one address or a list of domains.
struct RemoteDraft: Equatable {
    var title: String
    var url: String?
    var domains: [String]?
    var refreshInterval: Int
}

/// Which remote entry the sheet is working on.
enum RemotePrompt: Identifiable {
    case new
    case edit(HostsNode)

    var id: String {
        switch self {
        case .new: return "new"
        case .edit(let node): return "edit-\(node.id)"
        }
    }
}

/// Create or edit a remote entry: its source (an address or domains), and how
/// often it refreshes.
struct RemoteSheet: View {
    let prompt: RemotePrompt
    let onSave: (RemoteDraft) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var usesDomains = false
    @State private var address = ""
    @State private var domainText = ""
    @State private var interval = 0

    private static let intervals: [(label: LocalizedStringKey, seconds: Int)] = [
        ("Manual", 0),
        ("Every hour", 3600),
        ("Every day", 86400),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(isNew ? LocalizedStringKey("New Remote Entry") : LocalizedStringKey("Edit Remote Entry")).font(.headline)

            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .disabled(!isNew)

            Picker("Source", selection: $usesDomains) {
                Text("URL").tag(false)
                Text("Domains").tag(true)
            }
            .pickerStyle(.segmented)

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
                TextField("https://example.com/hosts", text: $address)
                    .textFieldStyle(.roundedBorder)
            }

            Picker("Refresh interval", selection: $interval) {
                ForEach(Self.intervals, id: \.seconds) { option in
                    Text(option.label).tag(option.seconds)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear(perform: load)
    }

    private var isNew: Bool {
        if case .new = prompt { return true }
        return false
    }

    private var canSave: Bool {
        if title.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return usesDomains ? !domains.isEmpty : !address.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var domains: [String] {
        domainText
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func load() {
        guard case .edit(let node) = prompt else { return }
        title = node.title ?? node.id
        usesDomains = node.source == "domain"
        address = node.url ?? ""
        domainText = (node.domains ?? []).joined(separator: "\n")
        interval = node.refreshInterval ?? 0
    }

    private func submit() {
        let draft = RemoteDraft(
            title: title.trimmingCharacters(in: .whitespaces),
            url: usesDomains ? nil : address.trimmingCharacters(in: .whitespaces),
            domains: usesDomains ? domains : nil,
            refreshInterval: interval
        )
        onSave(draft)
        dismiss()
    }
}
