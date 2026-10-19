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

    private static func effect(of mode: Int) -> LocalizedStringKey {
        switch mode {
        case 1: return "Only one item directly inside this folder can be enabled at a time."
        case 2: return "Multiple items directly inside this folder can be enabled at the same time."
        default: return "Inherits the global choice mode from Preferences."
        }
    }
}
