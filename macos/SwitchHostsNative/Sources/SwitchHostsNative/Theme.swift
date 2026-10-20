import AppKit
import SwiftUI
import SwitchHostsCore

// Shared pieces that give the windows one look: the brand colours, small
// tags, centred empty states, and banners for progress, notices, and errors.
// Backgrounds, separators, and secondary text use the system's semantic colours.

/// The brand colours of the 1c design, each with a light and a dark value.
/// The red accent and its soft background come from the Tauri version.
enum Brand {
    static let accent = dynamic(light: 0xc9364f, dark: 0xd46a7e)
    /// The soft background of a selected sidebar row or an enabled tag.
    static let accentSoft = dynamic(light: 0xf7dce2, dark: 0x623b47)
    /// Text and icons on `accentSoft`.
    static let accentInk = dynamic(light: 0x98283b, dark: 0xf2cdd5)
    /// The address at the start of a hosts line.
    static let ip = dynamic(light: 0x8250b0, dark: 0xcba2f2)
    static let comment = dynamic(light: 0x8a8380, dark: 0x9a938f)
    static let gutter = dynamic(light: 0xbbb6b3, dark: 0x625d5a)
    static let switchOff = dynamic(light: 0xd9d7d5, dark: 0x4d4a48)
    static let findHighlight = dynamic(light: 0xfff0a0, dark: 0x6b5d1f)

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    private static func rgb(_ value: UInt32) -> NSColor {
        NSColor(
            srgbRed: CGFloat((value >> 16) & 0xff) / 255,
            green: CGFloat((value >> 8) & 0xff) / 255,
            blue: CGFloat(value & 0xff) / 255,
            alpha: 1
        )
    }
}

extension Color {
    static let accent = Color(nsColor: Brand.accent)
    static let accentSoft = Color(nsColor: Brand.accentSoft)
    static let accentInk = Color(nsColor: Brand.accentInk)
    static let switchOff = Color(nsColor: Brand.switchOff)
    static let findHighlight = Color(nsColor: Brand.findHighlight)
}

/// A rounded group of related controls or values.
struct Card<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A small caption above a card, like a grouped form's section title.
struct CardTitle: View {
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.leading, 4)
    }
}

/// The icon for a kind of entry, in the accent colour.
struct KindIcon: View {
    let symbol: String
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size))
            .foregroundStyle(Color.accent)
            .frame(width: size + 6)
    }
}

/// The top of a detail pane: a large title, and a row of tags or an accessory
/// beneath it.
struct PaneHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.system(size: 22, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            accessory()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A small rounded tag, as the detail header shows the kind and the state.
struct Tag: View {
    enum Style {
        /// Grey, for facts such as the kind.
        case plain
        /// The soft accent with a dot, for an enabled entry.
        case enabled
        /// No background, for counts.
        case bare
    }

    let text: Text
    var style: Style = .plain

    init(_ text: Text, style: Style = .plain) {
        self.text = text
        self.style = style
    }

    init(_ key: LocalizedStringKey, style: Style = .plain) {
        self.init(Text(key), style: style)
    }

    var body: some View {
        HStack(spacing: 4) {
            if style == .enabled {
                Circle()
                    .fill(Color.accent)
                    .frame(width: 5, height: 5)
            }
            text
        }
        .font(.system(size: 11))
        .lineLimit(1)
        .foregroundStyle(foreground)
        .padding(.horizontal, style == .bare ? 0 : 7)
        .padding(.vertical, 2.5)
        .background(background, in: RoundedRectangle(cornerRadius: 10))
    }

    private var foreground: Color {
        switch style {
        case .plain, .bare: return .secondary
        case .enabled: return .accentInk
        }
    }

    private var background: Color {
        switch style {
        case .plain: return Color.secondary.opacity(0.12)
        case .enabled: return .accentSoft
        case .bare: return .clear
        }
    }
}

/// The switch on the list rows: a track in the accent colour when on and a
/// neutral one when off. On a selected (accent) row it inverts: a white track
/// with an accent knob. It stays a `Toggle`, so it reads as a switch to
/// accessibility; the system switch cannot take these colours.
struct BrandSwitchStyle: ToggleStyle {
    enum Size {
        case regular
        case small
    }

    var size: Size = .regular
    /// Whether the row behind the switch is filled with the accent colour.
    var onAccent = false

    func makeBody(configuration: Configuration) -> some View {
        BrandSwitch(configuration: configuration, size: size, onAccent: onAccent)
    }

    private struct BrandSwitch: View {
        let configuration: Configuration
        let size: Size
        let onAccent: Bool
        @Environment(\.isEnabled) private var isEnabled

        private var width: CGFloat { size == .regular ? 32 : 26 }
        private var height: CGFloat { size == .regular ? 18 : 15 }

        var body: some View {
            let isOn = configuration.isOn
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(track(isOn))
                Circle()
                    .fill(knob(isOn))
                    .shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(2)
            }
            .frame(width: width, height: height)
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Capsule())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.15)) { configuration.isOn.toggle() }
            }
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }
            }
        }

        private func track(_ isOn: Bool) -> Color {
            if onAccent { return .white.opacity(isOn ? 0.95 : 0.3) }
            return isOn ? .accent : .switchOff
        }

        private func knob(_ isOn: Bool) -> Color {
            onAccent && isOn ? .accent : .white
        }
    }
}

/// A centred placeholder for an empty pane.
struct EmptyState: View {
    let symbol: String
    let message: LocalizedStringKey

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// On or off, as a coloured dot and a word.
struct StatusDot: View {
    let isOn: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isOn ? Color.accent : Color.secondary.opacity(0.5))
                .frame(width: 7, height: 7)
            Text(LocalizedStringKey(isOn ? "Enabled" : "Disabled"))
        }
    }
}

/// A floating message at the bottom of the window: progress, a notice, or an error.
struct Banner<Actions: View>: View {
    enum Style {
        case progress
        case notice
        case error
    }

    let style: Style
    let message: String
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            switch style {
            case .progress:
                ProgressView().controlSize(.small)
            case .notice:
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accent)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            Text(verbatim: message)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            actions()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
    }
}

/// A small close button for banners.
struct DismissButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A full-width button that looks like a menu item: highlighted under the pointer.
struct MenuRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuRow(configuration: configuration)
    }

    private struct MenuRow: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovering = false

        var body: some View {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(hovering ? Color.white : Color.primary)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(hovering ? Color.accent : Color.clear)
                )
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The frame every sheet shares: the title on top, the content, and a footer
/// with the actions on the right.
struct SheetLayout<Content: View, Footer: View>: View {
    let title: Text
    var width: CGFloat = 480
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
                .font(.system(size: 15, weight: .bold))
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
            HStack(spacing: 8) {
                footer()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(.accent)
    }
}
