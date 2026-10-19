import AppKit
import SwiftUI
import SwitchHostsCore

/// Menu bar extra: the same tree with switches, in a small window. Clicking a
/// switch goes through the core like the main window does.
struct MenuBarView: View {
    @ObservedObject var model: HostsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TrayHeader()
            Divider()
            TrayEntries(model: model)
            Divider()
            TrayFooter(model: model)
        }
        .frame(width: 290)
        .task { await model.reload() }
    }
}
