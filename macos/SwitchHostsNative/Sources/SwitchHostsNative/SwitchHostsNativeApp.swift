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
        }
        // The window cannot shrink below the content's minimum size, so nothing
        // at the edges (the sidebar's foot, the banners) is cut off.
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About SwitchHosts") { AboutPanel.show() }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Local Entry") { model.entryPrompt = .new(.local) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Remote Entry") { model.entryPrompt = .new(.remote) }
                Button("New Group") { model.entryPrompt = .new(.group) }
                Button("New Folder") { model.entryPrompt = .new(.folder) }
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
                Button("Feedback") { NSWorkspace.shared.open(AboutPanel.feedback) }
                Button("Homepage") { NSWorkspace.shared.open(AboutPanel.homepage) }
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

/// The status item's icon and optional title. The icon is 5.0.2's tray image,
/// shipped in the app bundle; a plain build without it uses a system symbol.
struct TrayLabel: View {
    @ObservedObject var model: HostsModel

    private static let icon: NSImage? = {
        guard let image = Bundle.main.image(forResource: "tray-mac") else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }()

    var body: some View {
        HStack(spacing: 4) {
            if let icon = Self.icon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "network")
            }
            if let title = model.trayTitle, !title.isEmpty {
                Text(title)
            }
        }
    }
}

/// The items of 5.0.2's tray menu, at the foot of both menu bar windows: show
/// the main window, show or hide the Dock icon, the version, and quit.
struct TrayFooter: View {
    @ObservedObject var model: HostsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            } label: {
                Label("Show Main Window", systemImage: "macwindow")
            }
            Button {
                Task { await model.setDockIconHidden(!model.dockIconHidden) }
            } label: {
                Label(model.dockIconHidden ? "Show Dock Icon" : "Hide Dock Icon", systemImage: "dock.rectangle")
            }
            Divider()
                .padding(.vertical, 4)
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Label("Quit", systemImage: "power")
                    Spacer()
                    Text(verbatim: "v\(Self.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(6)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// The app's name and icon at the top of the menu bar windows.
struct TrayHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 20, height: 20)
            Text("SwitchHosts")
                .font(.headline)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }
}

/// The compact list shown in the status item's window when the tray shortcut is off.
struct TrayMenu: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrayHeader()
            Divider()
            TrayEntries(model: model)
            Divider()
            TrayFooter(model: model)
        }
        .frame(width: 260)
        .task { await model.reload() }
    }
}

/// The entries with their switches, scrolling when the list is long.
struct TrayEntries: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(model.tree, id: \.id) { node in
                    TrayEntryRow(node: node, model: model, depth: 0)
                }
                if model.tree.isEmpty {
                    Text("No entries yet.")
                        .foregroundStyle(.secondary)
                        .padding(8)
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 380)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One entry: its icon, title, and switch; a folder's children follow, indented.
/// Folders switch too, as every row does in 5.0.2.
struct TrayEntryRow: View {
    let node: HostsNode
    @ObservedObject var model: HostsModel
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                KindIcon(symbol: node.symbolName, size: 12)
                Text(verbatim: node.title ?? node.id)
                    .fontWeight(node.isFolder ? .medium : .regular)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                Toggle(isOn: Binding(
                    get: { node.isOn },
                    set: { _ in Task { await model.toggle(node) } }
                )) {
                    Text(verbatim: node.title ?? node.id)
                }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
            }
            .padding(.leading, 8 + CGFloat(depth) * 14)
            .padding(.trailing, 8)
            .padding(.vertical, 4)
            ForEach(node.children ?? [], id: \.id) { child in
                TrayEntryRow(node: child, model: model, depth: depth + 1)
            }
        }
    }
}
