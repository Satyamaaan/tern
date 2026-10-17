import SwiftUI
import TernCore

/// A 1 px line in `hairline`.
struct Hairline: View {
    var vertical = false
    var color = Theme.hairline

    var body: some View {
        Rectangle()
            .fill(Color(color))
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

/// A square icon button with a hover fill (rows and icon buttons are the only things that hover).
struct IconButton: View {
    let icon: Icon
    var size: CGFloat = 28
    var iconSize: CGFloat = 15
    var help: String = ""
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: iconSize)
                .frame(width: size, height: size)
                .background(RoundedRectangle(cornerRadius: Theme.Radius.row).fill(Color(Theme.hover).opacity(hovering ? 1 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A shortcut key in Geist Mono, e.g. the `/` in the search pill or `⌘K` in the palette.
struct Keycap: View {
    let text: String
    var inverted = false

    var body: some View {
        Text(text)
            .font(.mono(11))
            .foregroundStyle(inverted ? Color(Theme.bg) : Color(Theme.text3))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(inverted ? Color.clear : Color(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(
                        inverted ? Color(Theme.bg).opacity(0.35) : Color(Theme.hairlineStrong), lineWidth: 1))
            )
    }
}

/// A chip: 12% tint, coloured text, radius 6, 18 px tall.
struct Chip: View {
    let text: String
    let color: NSColor

    var body: some View {
        Text(text)
            .font(.ui(11, .medium))
            .foregroundStyle(Color(color))
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: Theme.Radius.chip).fill(Color(color).opacity(0.12)))
    }
}

/// A small coloured circle (account hue, status).
struct Dot: View {
    let color: NSColor
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(Color(color)).frame(width: size, height: size)
    }
}

/// Section caps: Geist 11/14 500, +0.6 tracking, `text3`.
struct CapsLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.ui(11, .medium))
            .tracking(0.6)
            .foregroundStyle(Color(Theme.text3))
    }
}

/// The project's SF Symbol (or emoji), tinted with its colour on a 16% tint square.
struct ProjectGlyph: View {
    let project: Project
    var size: CGFloat = 15

    var body: some View {
        let color = Color(Theme.projectColor(project.colorIndex))
        ZStack {
            RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.16))
            if let icon = project.icon, icon.unicodeScalars.first?.properties.isEmojiPresentation == true {
                Text(icon).font(.system(size: size * 0.62))
            } else {
                Image(systemName: project.icon ?? "folder")
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}

extension View {
    /// The overlay shadow from the spec (palette, menus, toasts).
    func overlayShadow() -> some View {
        modifier(OverlayShadow())
    }
}

private struct OverlayShadow: ViewModifier {
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.14), radius: 15, y: 8)
    }
}
