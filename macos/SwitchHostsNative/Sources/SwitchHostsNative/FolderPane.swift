import SwiftUI
import SwitchHostsCore

/// A folder's settings, at the head of the list when the folder's view is
/// shown: its choice mode, which decides how its children switch on and off,
/// and its own switch. A folder has no content of its own.
struct FolderControls: View {
    @ObservedObject var model: HostsModel
    let folder: HostsNode

    var body: some View {
        Picker("Choice Mode", selection: Binding(
            get: { folder.folderMode ?? 0 },
            set: { value in Task { await model.setFolderMode(folder.id, mode: value) } }
        )) {
            Text("Default").tag(0)
            Text("Single").tag(1)
            Text("Multiple").tag(2)
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help(Text(Self.effect(of: folder.folderMode ?? 0)))
        // Switching a folder switches its children by its choice mode (the core's rule).
        Toggle(
            folder.title ?? folder.id,
            isOn: Binding(
                get: { folder.isOn },
                set: { _ in Task { await model.toggle(folder) } }
            )
        )
        .labelsHidden()
        .toggleStyle(BrandSwitchStyle())
        .help(Text(folder.isOn ? "Enabled" : "Disabled"))
    }

    static func effect(of mode: Int) -> LocalizedStringKey {
        switch mode {
        case 1: return "Only one item directly inside this folder can be enabled at a time."
        case 2: return "Multiple items directly inside this folder can be enabled at the same time."
        default: return "Inherits the global choice mode from Preferences."
        }
    }
}

/// The entries a group lists, or a trashed folder holds. As in 5.0.2 a group
/// has no editable content: it lists the local and remote entries it
/// includes, and is changed with Edit.
struct GroupPane: View {
    let entries: [HostsNode]
    let emptyMessage: LocalizedStringKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardTitle("Content")
            Card {
                if entries.isEmpty {
                    Text(emptyMessage)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(entries) { entry in
                        EntrySummaryRow(node: entry)
                    }
                }
            }
        }
    }
}

/// One entry inside a group: its icon, title, and whether it is on.
private struct EntrySummaryRow: View {
    let node: HostsNode

    var body: some View {
        HStack(spacing: 8) {
            KindIcon(symbol: node.symbolName)
            Text(verbatim: node.title ?? node.id)
                .lineLimit(1)
            Spacer(minLength: 8)
            StatusDot(isOn: node.isOn)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
