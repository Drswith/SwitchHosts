import AppKit
import SwiftUI
import SwitchHostsCore

// Shared pieces that give the windows one look: rounded cards on the window
// background, a header with the entry's icon, centred empty states, and
// banners for progress, notices, and errors.

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
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
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

/// The icon for a kind of entry, tinted like a Finder sidebar icon.
struct KindIcon: View {
    let symbol: String
    var size: CGFloat = 13

    var body: some View {
        Image(systemName: symbol)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: size))
            .foregroundStyle(Color.accentColor)
            .frame(width: size + 6)
    }
}

/// The top of a detail pane or panel: a large icon, the title, and a subtitle.
struct PaneHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    let subtitle: LocalizedStringKey
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            accessory()
        }
    }
}

extension PaneHeader where Accessory == EmptyView {
    init(symbol: String, title: String, subtitle: LocalizedStringKey) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
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
                .fill(isOn ? Color.green : Color.secondary.opacity(0.5))
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
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
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
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.1)))
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
                        .fill(hovering ? Color.accentColor : Color.clear)
                )
                .opacity(configuration.isPressed ? 0.8 : 1)
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

/// The frame every sheet shares: an icon and title on top, the content, and a
/// footer bar with the actions.
struct SheetLayout<Content: View, Footer: View>: View {
    let symbol: String
    let title: Text
    var width: CGFloat = 480
    @ViewBuilder var content: () -> Content
    @ViewBuilder var footer: () -> Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: 17))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 30, height: 30)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                title
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 14)
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 18)
            Divider()
            HStack(spacing: 8) {
                footer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.6))
        }
        .frame(width: width)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
