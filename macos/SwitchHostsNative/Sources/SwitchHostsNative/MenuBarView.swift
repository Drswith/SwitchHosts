import AppKit
import SwiftUI
import SwitchHostsCore

/// Menu bar extra: the same tree with switches, in a small window. Clicking a
/// switch goes through the core like the main window does.
struct MenuBarView: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrayHeader(model: model)
            Divider()
            TrayEntries(model: model)
            Divider()
            TrayFooter(model: model)
        }
        .frame(width: 300)
        .task { await model.reload() }
    }
}

/// The compact list shown in the status item's window when the tray shortcut is off.
struct TrayMenu: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrayHeader(model: model)
            Divider()
            TrayEntries(model: model)
            Divider()
            TrayFooter(model: model)
        }
        .frame(width: 260)
        .task { await model.reload() }
    }
}

/// The app's icon and name at the top of the menu bar windows, how many
/// entries are on, and a button that opens the main window.
struct TrayHeader: View {
    @ObservedObject var model: HostsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text("SwitchHosts")
                    .font(.system(size: 13, weight: .semibold))
                Text("^[\(model.counts.active) entry](inflect: true) in effect")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                closeTrayWindow()
                openWindow.showMainWindow()
            } label: {
                Image(systemName: "macwindow")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show Main Window")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// The entries with their switches, scrolling when the list is long.
struct TrayEntries: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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

/// One entry: its icon, title, and mini switch; a folder's children follow,
/// indented. Entries that are on are set in bold. Folders switch too, as every
/// row does in 5.0.2.
struct TrayEntryRow: View {
    let node: HostsNode
    @ObservedObject var model: HostsModel
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: node.symbolName)
                    .font(.system(size: 12))
                    .foregroundStyle(node.isOn ? Color.accent : Color.secondary)
                    .frame(width: 16)
                Text(verbatim: node.title ?? node.id)
                    .font(.system(size: 13, weight: node.isOn ? .semibold : .regular))
                    .foregroundStyle(node.isOn ? Color.primary : Color.secondary)
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
            .padding(.leading, 8 + CGFloat(depth) * 18)
            .padding(.trailing, 8)
            .padding(.vertical, 5)
            ForEach(node.children ?? [], id: \.id) { child in
                TrayEntryRow(node: child, model: model, depth: depth + 1)
            }
        }
    }
}

/// The items of 5.0.2's tray menu, at the foot of both menu bar windows: show
/// the main window, show or hide the Dock icon, quit, and the version.
struct TrayFooter: View {
    @ObservedObject var model: HostsModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button {
                closeTrayWindow()
                openWindow.showMainWindow()
            } label: {
                Text("Show Main Window")
            }
            Button {
                closeTrayWindow()
                Task { await model.setDockIconHidden(!model.dockIconHidden) }
            } label: {
                Text(model.dockIconHidden ? "Show Dock Icon" : "Hide Dock Icon")
            }
            Divider()
                .padding(.vertical, 4)
            Button {
                NSApp.terminate(nil)
            } label: {
                HStack {
                    Text("Quit SwitchHosts")
                    Spacer()
                    Text(verbatim: "⌘Q")
                        .foregroundStyle(.secondary)
                }
            }
            .keyboardShortcut("q", modifiers: .command)
            Text(verbatim: "v\(Self.version)")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
                .padding(.top, 2)
        }
        .buttonStyle(MenuRowButtonStyle())
        .padding(6)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// Closes the menu bar window, as a menu closes once an item is chosen. The
/// window style stays open after a button in it runs, and SwiftUI has no call
/// that closes it. Closing the window itself leaves the status item thinking
/// it is still open, so its next click does nothing; this goes the way
/// Escape does instead.
@MainActor
private func closeTrayWindow() {
    // The status item's window is a panel; the main and settings windows are not.
    guard NSApp.keyWindow is NSPanel else { return }
    NSApp.sendAction(#selector(NSResponder.cancelOperation(_:)), to: nil, from: nil)
}

extension OpenWindowAction {
    /// Brings the main window forward, or opens it when there is none. Opening
    /// the window group again would stack a second main window over the first.
    @MainActor
    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        // SwiftUI names the group's windows "main-AppWindow-<n>".
        let open = NSApp.windows.first {
            $0.identifier?.rawValue.hasPrefix("main-") == true && ($0.isVisible || $0.isMiniaturized)
        }
        if let open {
            open.deminiaturize(nil)
            open.makeKeyAndOrderFront(nil)
        } else {
            self(id: "main")
        }
    }
}
