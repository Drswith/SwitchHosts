import AppKit
import SwiftUI
import SwitchHostsCore

/// Settings that the app itself reads, kept here so the delegate can see them.
enum AppBehavior {
    /// Whether closing the last window quits the app (preference `quit_on_close`).
    static var quitOnClose = false
}

/// Only what SwiftUI cannot express: whether the app quits when its last window closes.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppBehavior.quitOnClose
    }
}

@main
struct SwitchHostsNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = HostsModel()

    var body: some Scene {
        WindowGroup("SwitchHosts", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 420, minHeight: 320)
        }
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SwitchHosts") {
                    NSApp.orderFrontStandardAboutPanel(nil)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Local Entry") { model.newEntryRequest = .local }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Remote Entry") { model.newEntryRequest = .remote }
                Divider()
                Button("Import Backup…") { model.importBackupWithPanel() }
                Button("Import from URL…") { model.showImportURL = true }
                Button("Export Backup…") { model.exportBackupWithPanel() }
            }
            CommandGroup(replacing: .textEditing) {
                Button("Find and Replace…") { model.showFind = true }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Comment / Uncomment") {
                    NotificationCenter.default.post(name: .toggleComment, object: nil)
                }
                .keyboardShortcut("/", modifiers: .command)
            }
            CommandGroup(replacing: .help) {
                Button("Feedback") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/oldj/SwitchHosts/issues")!)
                }
                Button("Homepage") {
                    NSWorkspace.shared.open(URL(string: "https://switchhosts.app")!)
                }
            }
        }

        Settings {
            PreferencesView(model: model)
        }

        // One status item. With the tray shortcut on it opens the switch panel;
        // with it off it opens a compact list of the same entries.
        MenuBarExtra {
            if model.trayMiniWindow {
                MenuBarView(model: model)
            } else {
                TrayMenu(model: model)
            }
        } label: {
            TrayLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The status item's icon and optional title.
struct TrayLabel: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "network")
            if let title = model.trayTitle, !title.isEmpty {
                Text(title)
            }
        }
    }
}

/// The compact list shown in the status item's window when the tray shortcut is off.
struct TrayMenu: View {
    @ObservedObject var model: HostsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.tree, id: \.id) { node in
                TrayMenuItem(node: node, model: model, depth: 0)
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
        }
        .padding(12)
        .frame(width: 240)
        .task { await model.reload() }
    }
}

/// One entry in the compact list: a switch for entries, indented children for folders.
private struct TrayMenuItem: View {
    let node: HostsNode
    @ObservedObject var model: HostsModel
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if node.isFolder {
                Text(node.title ?? node.id).fontWeight(.semibold)
            } else {
                Toggle(node.title ?? node.id, isOn: Binding(
                    get: { node.isOn },
                    set: { _ in Task { await model.toggle(node) } }
                ))
                .toggleStyle(.switch)
            }
            ForEach(node.children ?? [], id: \.id) { child in
                TrayMenuItem(node: child, model: model, depth: depth + 1)
                    .padding(.leading, 14)
            }
        }
    }
}
