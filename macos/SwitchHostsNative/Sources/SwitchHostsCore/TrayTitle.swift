import Foundation

/// The menu bar title for "show title on tray": the titles of every entry that
/// is on, comma-separated and shortened when long. Same rules as the Tauri tray.
public enum TrayTitle {
    /// Longest title shown before truncation, counted in Unicode scalars like Rust `chars()`.
    public static let maxLength = 20
    /// Characters kept when truncating; the rest is replaced with "...".
    public static let keptLength = 17

    public static func make(_ nodes: [HostsNode], show: Bool) -> String? {
        guard show else { return nil }
        var titles: [String] = []
        collectOnTitles(nodes, into: &titles)
        var joined = titles.joined(separator: ",")
        let scalars = Array(joined.unicodeScalars)
        if scalars.count > maxLength {
            var kept = String.UnicodeScalarView()
            kept.append(contentsOf: scalars.prefix(keptLength))
            joined = String(kept) + "..."
        }
        return joined
    }

    private static func collectOnTitles(_ nodes: [HostsNode], into titles: inout [String]) {
        for node in nodes {
            if node.isOn, let title = node.title {
                titles.append(title)
            }
            collectOnTitles(node.children ?? [], into: &titles)
        }
    }
}
