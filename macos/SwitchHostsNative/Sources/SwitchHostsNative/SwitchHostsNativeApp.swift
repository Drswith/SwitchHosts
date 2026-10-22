import AppKit
import SwiftUI
import SwitchHostsCore

/// Settings that the app itself reads, kept here so the delegate can see them.
enum AppBehavior {
    /// Whether closing the last window quits the app (preference `quit_on_close`).
    static var quitOnClose = false
    /// Whether the main window stays closed at launch (preference `hide_at_launch`).
    @MainActor static var hidesAtLaunch = false
    /// Set at launch before macOS 15 when "hide at launch" is on. Those systems
    /// always open the main window, so it closes itself as soon as it shows.
    @MainActor static var closesMainWindowAtLaunch = false
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
            let quit = await beforeQuit()
            if !quit { AppRelaunch.requested = false }
            sender.reply(toApplicationShouldTerminate: quit)
        }
        return .terminateLater
    }

    @MainActor
    func applicationWillTerminate(_ notification: Notification) {
        if AppRelaunch.requested { AppRelaunch.launchReplacement() }
    }
}

@main
struct SwitchHostsNativeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: HostsModel
    /// The `hide_at_launch` preference, read before any scene is made.
    private let hidesAtLaunch: Bool

    init() {
        // AppKit offers password and one-time-code AutoFill in every text field
        // that takes focus, which starts Safari's AutoFill helper process (about
        // 12 MB) for the rest of the session. Setting a field's content type
        // does not stop it. Nothing here signs in, so the heuristics are off.
        UserDefaults.standard.register(defaults: ["NSAutoFillHeuristicsEnabled": false])
        let model = HostsModel()
        hidesAtLaunch = model.openAtLaunch()
        AppBehavior.hidesAtLaunch = hidesAtLaunch
        if #unavailable(macOS 15.0) {
            AppBehavior.closesMainWindowAtLaunch = hidesAtLaunch
        }
        _model = StateObject(wrappedValue: model)
        // The tray needs the model whether or not the main window opens.
        Task { await model.start() }
    }

    var body: some Scene {
        mainWindow
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

        // One status item; it opens the switch panel.
        MenuBarExtra {
            MenuBarView(model: model)
                .tint(.accent)
        } label: {
            TrayLabel(model: model)
        }
        .menuBarExtraStyle(.window)
    }

    /// The main window. A window group rather than a single `Window`, because
    /// a closed group window is freed while a `Window` is kept in memory; Show
    /// Main Window brings an open one forward instead of opening another. With
    /// "hide at launch" on, macOS 15 and later do not make it at launch at
    /// all; earlier systems close it as it opens.
    private var mainWindow: some Scene {
        let window = WindowGroup("SwitchHosts", id: "main") {
            ContentView(model: model)
        }
        if #available(macOS 15.0, *) {
            return window.defaultLaunchBehavior(hidesAtLaunch ? .suppressed : .automatic)
        } else {
            return window
        }
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
