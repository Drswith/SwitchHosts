import AppKit
import SwiftUI
import SwitchHostsCore

/// Saved states of the system hosts file, newest first. Each can be read and
/// deleted; the limit and the recording switch are the same settings as 5.0.2.
struct HistorySheet: View {
    @ObservedObject var model: HostsModel
    @Environment(\.dismiss) private var dismiss

    @State private var records: [ApplyRecord] = []
    @State private var selectedID: String?
    @State private var recording = true
    @State private var limit = 50

    private var limitChoices: [Int] {
        Array(Set([10, 50, 100, 500, limit])).sorted()
    }

    private var selected: ApplyRecord? {
        records.first { $0.id == selectedID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("System Hosts Version History")
                .font(.headline)

            HStack {
                Toggle("Record history", isOn: Binding(
                    get: { recording },
                    set: { value in
                        recording = value
                        Task { await model.updateConfig(["history_enabled": value]) }
                    }
                ))
                Spacer()
                Picker("Maximum Number of Records", selection: Binding(
                    get: { limit },
                    set: { value in Task { await changeLimit(to: value) } }
                )) {
                    ForEach(limitChoices, id: \.self) { value in
                        Text(value == 0 ? LocalizedStringKey("Unlimited") : LocalizedStringKey(String(value))).tag(value)
                    }
                }
                .frame(width: 260)
            }

            if !recording {
                Text("Recording is off. Existing history can still be viewed and deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if records.isEmpty {
                Text("No Records")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 300)
            } else {
                HStack(spacing: 12) {
                    List(records, selection: $selectedID) { record in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.date.formatted(date: .numeric, time: .standard))
                            HStack(spacing: 6) {
                                Text("\(record.content.split(separator: "\n", omittingEmptySubsequences: false).count) lines")
                                Text(ByteCountFormatter.string(fromByteCount: Int64(record.content.utf8.count), countStyle: .file))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .tag(record.id)
                    }
                    .frame(width: 240)

                    HighlightingEditor(text: .constant(selected?.content ?? ""), readOnly: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 300)
            }

            HStack {
                Button("Clear History", role: .destructive) {
                    Task { await confirmClear() }
                }
                .disabled(records.isEmpty)
                Spacer()
                Button("Delete selected") {
                    Task { await confirmDelete() }
                }
                .disabled(selected == nil)
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 760, height: 520)
        .task { await load() }
    }

    private func load() async {
        let settings = await model.historySettings()
        recording = settings.enabled
        limit = settings.limit
        await reload()
    }

    private func reload() async {
        records = await model.applyHistory()
        if selectedID == nil || !records.contains(where: { $0.id == selectedID }) {
            selectedID = records.first?.id
        }
    }

    /// Lowering the limit deletes the oldest records, so the user confirms the count first.
    private func changeLimit(to value: Int) async {
        guard value != limit else { return }
        if let preview = await model.setHistoryLimit(value) {
            let alert = NSAlert()
            alert.messageText = String(localized: "Reduce history retention?")
            alert.informativeText = String(localized: "\(preview.deleteCount) saved records will be deleted and \(preview.retainedCount) kept. Deleted records cannot be recovered.")
            alert.addButton(withTitle: String(localized: "Save and delete \(preview.deleteCount) records"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            await model.setHistoryLimit(value, confirmation: preview)
        }
        limit = value
        await reload()
    }

    private func confirmDelete() async {
        guard let record = selected else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Delete selected")
        alert.informativeText = String(localized: "Are you sure you want to delete this item?")
        alert.addButton(withTitle: String(localized: "Delete"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        _ = await model.deleteApplyRecord(record.id)
        await reload()
    }

    private func confirmClear() async {
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear History")
        alert.informativeText = String(localized: "Clear all system hosts history? This cannot be undone.")
        alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        await model.clearApplyHistory()
        await reload()
    }
}
