import AppKit
import SwiftUI
import SwitchHostsCore

/// Settings that the app itself reads, kept here so the delegate can see them.
enum AppBehavior {
    /// Whether closing the last window quits the app (preference `quit_on_close`).
    static var quitOnClose = false
    /// Whether the editor holds edits that are not saved yet.
    @MainActor static var hasUnsavedEdits: () -> Bool = { false }
    /// Runs before the app quits when there are unsaved edits: saves them.
    /// Returns false to stay open.
    @MainActor static var beforeQuit: (() async -> Bool)?
}

/// Only what SwiftUI cannot express: whether the app quits when its last
/// window closes, and saving the editor before it quits.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        AppBehavior.quitOnClose
    }

    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Quitting waits only when there is something to save.
        guard AppBehavior.hasUnsavedEdits(), let beforeQuit = AppBehavior.beforeQuit else { return .terminateNow }
        Task { @MainActor in
            sender.reply(toApplicationShouldTerminate: await beforeQuit())
        }
        return .terminateLater
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
                Button("New Local Entry") { model.promptNew(.local) }
                    .keyboardShortcut("n", modifiers: .command)
                Button("New Remote Entry") { model.promptNew(.remote) }
                Button("New Group") { model.promptNew(.group) }
                Button("New Folder") { model.promptNew(.folder) }
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
                .tint(.accent)
        }

        // One status item. With the tray shortcut on it opens the switch panel;
        // with it off it opens a compact list of the same entries.
        MenuBarExtra {
            Group {
                if model.trayMiniWindow {
                    MenuBarView(model: model)
                } else {
                    TrayMenu(model: model)
                }
            }
            .tint(.accent)
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
