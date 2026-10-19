import SwiftUI

/// Asks for a backup address. The window then downloads it and shows the same
/// preview as a file import, so the sheet closes first.
struct ImportURLSheet: View {
    @ObservedObject var model: HostsModel
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""

    var body: some View {
        SheetLayout(symbol: "link", title: Text("Import from URL"), width: 460) {
            Card {
                TextField("https://example.com/backup.json", text: $address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                Text("The address must return a SwitchHosts backup file (JSON).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Import", action: submit)
                .keyboardShortcut(.defaultAction)
                .disabled(!isValid)
        }
    }

    private var isValid: Bool {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    private func submit() {
        guard isValid else { return }
        let text = address
        dismiss()
        Task { await model.beginImport(fromURL: text) }
    }
}
