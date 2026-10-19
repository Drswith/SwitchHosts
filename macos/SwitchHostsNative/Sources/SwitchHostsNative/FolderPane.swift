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
        VStack(alignment: .leading, spacing: 12) {
            Text(node.title ?? node.id)
                .font(.title3.weight(.semibold))
            Text("Choice Mode")
                .font(.headline)
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
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(node.title ?? node.id)
                    .font(.title3.weight(.semibold))
                Spacer()
                Button("Edit…") { model.entryPrompt = .edit(node) }
            }
            Text("Content")
                .font(.headline)
            if included.isEmpty {
                Text("No entries included.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(included) { entry in
                    Label(entry.title ?? entry.id, systemImage: entry.symbolName)
                }
            }
            Spacer()
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
