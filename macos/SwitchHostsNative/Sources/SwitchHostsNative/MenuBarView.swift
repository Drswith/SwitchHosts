import AppKit
import SwiftUI
import SwitchHostsCore

/// Menu bar extra: the same tree with switches, in a small window. Clicking a
/// switch goes through the core like the main window does.
struct MenuBarView: View {
    @ObservedObject var model: HostsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SwitchHosts").font(.headline)
            Divider()
            ForEach(model.tree, id: \.id) { node in
                MenuBarRow(node: node, model: model)
            }
            if model.tree.isEmpty {
                Text("No entries yet.").foregroundStyle(.secondary)
            }
            Divider()
            Button("Open SwitchHosts") {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }
            Button("Quit SwitchHosts") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 280)
        .task { await model.reload() }
    }
}

/// One entry in the menu bar window, with its children indented.
private struct MenuBarRow: View {
    let node: HostsNode
    @ObservedObject var model: HostsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !node.isFolder {
                Toggle(isOn: Binding(
                    get: { node.isOn },
                    set: { _ in Task { await model.toggle(node) } }
                )) {
                    Text(node.title ?? node.id)
                }
                .toggleStyle(.switch)
            } else {
                Text(node.title ?? node.id).fontWeight(.semibold)
            }
            ForEach(node.children ?? [], id: \.id) { child in
                MenuBarRow(node: child, model: model)
                    .padding(.leading, 14)
            }
        }
    }
}
