import SwiftUI
import SwitchHostsCore

/// Find and replace across every entry. Matching and replacement run in the
/// Rust core; this view only collects the query and shows the results,
/// grouped by entry.
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
    @State private var status = ""
    @State private var searched = false

    /// Matches that can be replaced: those in local entries.
    private var replaceableCount: Int {
        results.filter { !$0.isReadOnly }.reduce(0) { $0 + $1.count }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                QueryField(symbol: "magnifyingglass", placeholder: "Find", text: $keyword, onSubmit: find) {
                    OptionButton(label: ".*", help: "Regular expression", isOn: $regexp)
                    // The core keeps "ignore case"; the button is on when case matters.
                    OptionButton(label: "Aa", help: "Match case", isOn: Binding(
                        get: { !ignoreCase },
                        set: { ignoreCase = !$0 }
                    ))
                    HistoryMenu(isEmpty: keywordHistory.isEmpty) {
                        ForEach(Array(keywordHistory.reversed().enumerated()), id: \.offset) { _, entry in
                            Button(entry.value) {
                                keyword = entry.value
                                regexp = entry.isRegexp
                                ignoreCase = entry.isIgnoreCase
                            }
                        }
                    }
                }
                QueryField(symbol: "arrow.2.squarepath", placeholder: "Replace with", text: $replacement, onSubmit: {}) {
                    HistoryMenu(isEmpty: replaceHistory.isEmpty) {
                        ForEach(Array(replaceHistory.reversed().enumerated()), id: \.offset) { _, text in
                            Button(text) { replacement = text }
                        }
                    }
                }
            }
            .padding(12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(results) { item in
                        ResultHeader(item: item)
                        ForEach(item.positions, id: \.start) { position in
                            ResultRow(
                                position: position,
                                canReplace: !keyword.isEmpty && !item.isReadOnly,
                                onShow: { Task { await model.show(item, position) } },
                                onReplace: { replace(item, position) }
                            )
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .frame(height: 260)
            .overlay {
                if searched && results.isEmpty {
                    Text("No matches.").foregroundStyle(.secondary)
                } else if !searched {
                    Image(systemName: "text.magnifyingglass")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(.tertiary)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Find", action: find)
                    .disabled(keyword.isEmpty)
                Button(action: replaceAll) {
                    Text("Replace All") + Text(verbatim: replaceableCount > 0 ? " (\(replaceableCount))" : "")
                }
                .buttonStyle(.borderedProminent)
                .disabled(keyword.isEmpty || replaceableCount == 0)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.accent)
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
            updateStatus()
        }
    }

    private func replace(_ item: FindItem, _ position: FindPosition) {
        Task {
            await model.recordReplace(replacement)
            replaceHistory = await model.replaceHistory()
            _ = await model.replaceOne(item, position: position, replacement: replacement)
            results = await model.findMatches(keyword: keyword, regexp: regexp, ignoreCase: ignoreCase)
            updateStatus()
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
            results = await model.findMatches(keyword: keyword, regexp: regexp, ignoreCase: ignoreCase)
            status = String(localized: "Replaced \(replaced).")
        }
    }

    /// "Matches: 4 in 2 entries (1 read-only)".
    private func updateStatus() {
        let total = results.reduce(0) { $0 + $1.count }
        let readOnly = results.filter(\.isReadOnly).count
        status = String(localized: "Matches: \(total) in \(results.count) entries")
        if readOnly > 0 {
            status += " " + String(localized: "(\(readOnly) read-only)")
        }
    }
}

/// A rounded field with an icon in front and small buttons inside on the right.
private struct QueryField<Trailing: View>: View {
    let symbol: String
    let placeholder: LocalizedStringKey
    @Binding var text: String
    let onSubmit: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .onSubmit(onSubmit)
            trailing()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// A small on/off option inside a field, such as ".*" for regular expressions.
private struct OptionButton: View {
    let label: String
    let help: LocalizedStringKey
    @Binding var isOn: Bool

    var body: some View {
        Button {
            isOn.toggle()
        } label: {
            Text(verbatim: label)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(isOn ? Color.accentInk : Color.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(isOn ? Color.accentSoft : Color.clear, in: RoundedRectangle(cornerRadius: 4))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(Text(help))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// The history menu at the end of a field: earlier searches or replacements.
private struct HistoryMenu<Items: View>: View {
    let isEmpty: Bool
    @ViewBuilder var items: () -> Items

    var body: some View {
        Menu {
            items()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isEmpty)
        .help("History")
    }
}

/// The entry a group of results belongs to: its icon, title, how many matches,
/// and a "Read Only" tag when it cannot be replaced in.
private struct ResultHeader: View {
    let item: FindItem

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(Color.accent)
            Text(verbatim: item.itemTitle)
                .font(.system(size: 12, weight: .semibold))
            Text("^[\(item.count) match](inflect: true)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            if item.isReadOnly {
                ReadOnlyBadge()
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var symbol: String {
        switch item.itemType {
        case "remote": return "globe"
        case "group": return "square.stack"
        case "folder": return "folder"
        default: return "doc.text"
        }
    }
}

/// One match: its line number (the core counts from 1), the text around it on
/// its line with the match highlighted, and Show and Replace. A double click
/// also shows it.
private struct ResultRow: View {
    let position: FindPosition
    let canReplace: Bool
    let onShow: () -> Void
    let onReplace: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(verbatim: "\(position.line)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(nsColor: Brand.gutter))
                .frame(width: 28, alignment: .trailing)
            Text(line)
                .font(.system(size: 12, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Show", action: onShow)
                .controlSize(.small)
            // Remote and other non-local entries cannot be replaced in, as in 5.0.2.
            Button("Replace", action: onReplace)
                .controlSize(.small)
                .disabled(!canReplace)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hovering ? Color.accentSoft.opacity(0.5) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: onShow)
    }

    /// The line around the match, with the match on the search highlight.
    private var line: AttributedString {
        var before = AttributedString(position.before)
        before.foregroundColor = .secondary
        var match = AttributedString(position.match)
        match.backgroundColor = .findHighlight
        match.foregroundColor = .primary
        var after = AttributedString(position.after)
        after.foregroundColor = .secondary
        return before + match + after
    }
}
