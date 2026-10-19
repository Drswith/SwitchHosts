import SwiftUI
import SwitchHostsCore

/// Find and replace across every entry. Matching and replacement run in the
/// Rust core; this view only collects the query and shows the results.
struct FindSheet: View {
    @ObservedObject var model: HostsModel
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var replacement = ""
    @State private var regexp = false
    @State private var ignoreCase = true
    @State private var results: [FindItem] = []
    @State private var keywordHistory: [FindHistoryEntry] = []
    @State private var replaceHistory: [String] = []

    /// One row per match, so each can be shown or replaced on its own.
    private var hits: [FindHit] {
        results.flatMap { item in item.positions.map { FindHit(item: item, position: $0) } }
    }
    @State private var status = ""
    @State private var searched = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find and Replace").font(.headline)

            HStack(spacing: 4) {
                TextField("Find", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(find)
                Menu {
                    ForEach(Array(keywordHistory.reversed().enumerated()), id: \.offset) { _, entry in
                        Button(entry.value) {
                            keyword = entry.value
                            regexp = entry.isRegexp
                            ignoreCase = entry.isIgnoreCase
                        }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(keywordHistory.isEmpty)
            }
            HStack(spacing: 4) {
                TextField("Replace with", text: $replacement)
                    .textFieldStyle(.roundedBorder)
                Menu {
                    ForEach(Array(replaceHistory.reversed().enumerated()), id: \.offset) { _, text in
                        Button(text) { replacement = text }
                    }
                } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(replaceHistory.isEmpty)
            }

            HStack {
                Toggle("Regular expression", isOn: $regexp)
                Toggle("Ignore case", isOn: $ignoreCase)
                Spacer()
            }

            List(hits) { hit in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.item.itemTitle)
                        Text("Line \(hit.position.line + 1): \(hit.position.match)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("Show") {
                        Task { await model.show(hit.item, hit.position) }
                    }
                    Button("Replace") {
                        Task {
                            await model.recordReplace(replacement)
                            replaceHistory = await model.replaceHistory()
                            _ = await model.replaceOne(hit.item, position: hit.position, replacement: replacement)
                            results = await model.findMatches(keyword: keyword, regexp: regexp, ignoreCase: ignoreCase)
                        }
                    }
                    .disabled(keyword.isEmpty)
                }
            }
            .frame(minHeight: 160)
            .overlay {
                if searched && results.isEmpty {
                    Text("No matches.").foregroundStyle(.secondary)
                }
            }

            if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }

            HStack {
                Button("Done") { dismiss() }
                Spacer()
                Button("Find", action: find)
                    .disabled(keyword.isEmpty)
                Button("Replace All", action: replaceAll)
                    .disabled(keyword.isEmpty || results.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task {
            let config = await model.loadConfig()
            regexp = config["find_is_regexp"] as? Bool ?? false
            ignoreCase = config["find_is_ignore_case"] as? Bool ?? false
            keywordHistory = await model.findHistory()
            replaceHistory = await model.replaceHistory()
        }
        .onChange(of: regexp) { value in
            Task { await model.updateConfig(["find_is_regexp": value]) }
        }
        .onChange(of: ignoreCase) { value in
            Task { await model.updateConfig(["find_is_ignore_case": value]) }
        }
    }

    private func find() {
        guard !keyword.isEmpty else { return }
        Task {
            await model.recordFind(keyword: keyword, regexp: regexp, ignoreCase: ignoreCase)
            keywordHistory = await model.findHistory()
            results = await model.findMatches(keyword: keyword, regexp: regexp, ignoreCase: ignoreCase)
            searched = true
            let total = results.reduce(0) { $0 + $1.count }
            status = String(localized: "Matches: \(total) in \(results.count) entries")
        }
    }

    private func replaceAll() {
        Task {
            await model.recordReplace(replacement)
            replaceHistory = await model.replaceHistory()
            let replaced = await model.replaceAll(
                keyword: keyword,
                regexp: regexp,
                ignoreCase: ignoreCase,
                replacement: replacement
            )
            status = String(localized: "Replaced \(replaced).")
            results = await model.findMatches(keyword: keyword, regexp: regexp, ignoreCase: ignoreCase)
        }
    }
}

/// A single match: the entry it belongs to and where it sits.
struct FindHit: Identifiable {
    let item: FindItem
    let position: FindPosition

    var id: String { "\(item.itemId)#\(position.start)" }
}
