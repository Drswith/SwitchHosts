import AppKit
import ServiceManagement

/// Login item (start at login) backed by SMAppService, the macOS 13+ API.
/// Registration only takes effect for a signed app bundle; from `swift run`
/// the call fails and the error is shown to the user.
enum LoginItem {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

/// Dock icon visibility, matching the `hide_dock_icon` preference.
enum DockIcon {
    static func apply(hidden: Bool) {
        NSApplication.shared.setActivationPolicy(hidden ? .accessory : .regular)
    }
}

/// The app's appearance, matching the `theme` preference: "light", "dark", or
/// anything else to follow the system.
enum AppTheme {
    static func apply(_ theme: String) {
        switch theme {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// Restarts the app: a new copy starts once this one has exited. Used after the
/// data folder changes, because the core opens its folder only at launch.
enum AppRelaunch {
    static func restart() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let bundle = Bundle.main.bundleURL.path.replacingOccurrences(of: "'", with: "'\\''")
        let script = "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open -n '\(bundle)'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        try? process.run()
        NSApp.terminate(nil)
    }
}
