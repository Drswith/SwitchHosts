import SwiftUI
import SwitchHostsCore

/// Settings for a folder, shown in the detail pane instead of an editor. A
/// folder has no content of its own; its choice mode decides how its children
/// switch on and off.
struct FolderPane: View {
    @ObservedObject var model: HostsModel
    let node: HostsNode

    var body: some View {
        let mode = node.folderMode ?? 0
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(symbol: "folder", title: node.title ?? node.id, subtitle: "Folder") {
                    Button("Edit…") { model.entryPrompt = .edit(node) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle("Choice Mode")
                    Card {
                        Picker("Choice Mode", selection: Binding(
                            get: { mode },
                            set: { value in Task { await model.setFolderMode(node.id, mode: value) } }
                        )) {
                            Text("Default").tag(0)
                            Text("Single").tag(1)
                            Text("Multiple").tag(2)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(maxWidth: 360)
                        Text(Self.effect(of: mode))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle("In This Folder")
                    Card {
                        let children = node.children ?? []
                        if children.isEmpty {
                            Text("No entries yet.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(children) { child in
                                EntrySummaryRow(node: child)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    static func effect(of mode: Int) -> LocalizedStringKey {
        switch mode {
        case 1: return "Only one item directly inside this folder can be enabled at a time."
        case 2: return "Multiple items directly inside this folder can be enabled at the same time."
        default: return "Inherits the global choice mode from Preferences."
        }
    }
}

/// A group in the detail pane. As in 5.0.2 it has no editable content: it
/// lists the local and remote entries it includes, and is changed with Edit.
struct GroupPane: View {
    @ObservedObject var model: HostsModel
    let node: HostsNode

    var body: some View {
        let included = model.includedNodes(of: node)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                PaneHeader(symbol: node.symbolName, title: node.title ?? node.id, subtitle: "Group") {
                    Button("Edit…") { model.entryPrompt = .edit(node) }
                }
                VStack(alignment: .leading, spacing: 6) {
                    CardTitle("Content")
                    Card {
                        if included.isEmpty {
                            Text("No entries included.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(included) { entry in
                                EntrySummaryRow(node: entry)
                            }
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }
}

/// One entry inside a folder or group pane: its icon, title, and whether it is on.
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
