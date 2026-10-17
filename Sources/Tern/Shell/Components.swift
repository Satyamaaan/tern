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
    var size: CGFloat = Theme.Control.regular
    var iconSize: CGFloat = 16
    var help: String = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: iconSize)
                .frame(width: size, height: size)
        }
        .buttonStyle(IconButtonStyle())
        .help(help)
    }
}

// MARK: - Buttons

/// Every text button in the app. 6 px corners, Inter Medium, 28 pt (24 pt small), no shadow.
/// - `primary`: `ink` fill, `onInk` label. One per area at most.
/// - `secondary`: 1 px `hairlineStrong` border, `hover` fill under the pointer.
/// - `quiet`: no border; the `hover` fill appears under the pointer.
/// All three darken a step while pressed, show an `ink` ring when focused from the keyboard and drop
/// to 40 % when disabled.
struct TernButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, quiet }
    enum Size { case regular, small }

    var kind: Kind
    var size: Size = .regular

    init(_ kind: Kind, size: Size = .regular) {
        self.kind = kind
        self.size = size
    }

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, kind: kind, size: size)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let kind: Kind
        let size: Size
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            configuration.label
                .font(.ui(size == .small ? 12 : 13, .medium))
                .lineLimit(1)
                .foregroundStyle(Color(kind == .primary ? Theme.onInk : Theme.text1))
                .padding(.horizontal, size == .small ? 10 : 12)
                .frame(height: size == .small ? Theme.Control.small : Theme.Control.regular)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(Color(Theme.hairlineStrong), lineWidth: kind == .secondary ? 1 : 0))
                .focusRing(isFocused, shape: shape)
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 && isEnabled }
        }

        private var fill: Color {
            let pressed = configuration.isPressed
            switch kind {
            case .primary:
                return Color(pressed ? Theme.inkPressed : hovering ? Theme.inkHover : Theme.ink)
            case .secondary, .quiet:
                return pressed ? Color(Theme.selected) : hovering ? Color(Theme.hover) : .clear
            }
        }
    }
}

/// Icon-only buttons: the label sets the size (28 pt by default); `hover` fill under the pointer,
/// `selected` while pressed, an `ink` ring when focused, 40 % when disabled.
struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
            configuration.label
                .background(shape.fill(
                    configuration.isPressed ? Color(Theme.selected) : hovering ? Color(Theme.hover) : .clear))
                .focusRing(isFocused, shape: shape)
                .contentShape(shape)
                .opacity(isEnabled ? 1 : 0.4)
                .onHover { hovering = $0 && isEnabled }
        }
    }
}

/// A text link in `ink`, underlined under the pointer ("Choose file…", "Add rule", "Undo").
struct LinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        StyledLink(configuration: configuration)
    }

    private struct StyledLink: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(Color(Theme.ink))
                .underline(hovering && isEnabled)
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// The keyboard focus ring: 1.5 px `ink` at 50 %, 2 px outside the control.
    func focusRing<S: InsettableShape>(_ visible: Bool, shape: S) -> some View {
        overlay(shape.inset(by: -2.5).strokeBorder(Color(Theme.ink).opacity(visible ? 0.5 : 0), lineWidth: 1.5))
    }
}

/// A shortcut key in Inter with tabular figures, e.g. the `/` in the search field or `⌘K` in the palette.
struct Keycap: View {
    let text: String
    var inverted = false

    var body: some View {
        Text(text)
            .font(.numeric(11))
            .foregroundStyle(inverted ? Color(Theme.bg) : Color(Theme.text3))
            .padding(.horizontal, 5)
            .frame(minWidth: 20, minHeight: 20)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.chip)
                    .fill(inverted ? Color.clear : Color(Theme.bg))
                    .overlay(RoundedRectangle(cornerRadius: Theme.Radius.chip).strokeBorder(
                        inverted ? Color(Theme.bg).opacity(0.35) : Color(Theme.hairlineStrong), lineWidth: 1))
            )
    }
}

/// A chip: 12% tint, coloured text, radius 4, 18 px tall.
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

/// A small circle (account hue, status). `ring` draws it hollow, for quiet states.
struct Dot: View {
    let color: NSColor
    var size: CGFloat = 7
    var ring = false

    var body: some View {
        Circle()
            .fill(Color(color).opacity(ring ? 0 : 1))
            .overlay(Circle().strokeBorder(Color(color), lineWidth: ring ? 1.25 : 0))
            .frame(width: size, height: size)
    }
}

/// Section caps: Inter 11/14 500, +0.6 tracking, `text3`.
struct CapsLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.ui(11, .medium))
            .tracking(0.6)
            .foregroundStyle(Color(Theme.text3))
    }
}

/// The project's icon (or emoji) in its colour: a tag icon, so it carries the project's hue.
struct ProjectGlyph: View {
    let project: Project
    var size: CGFloat = 16

    var body: some View {
        if let icon = project.icon, icon.unicodeScalars.first?.properties.isEmojiPresentation == true {
            Text(icon).font(.system(size: size * 0.8)).frame(width: size, height: size)
        } else {
            IconView(icon: Icon.project(project.icon), size: size, color: Color(Theme.projectColor(project.colorIndex)))
        }
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
        // Composited first, so rows inside (a highlighted palette or dropdown row) don't cast their own.
        content.compositingGroup().shadow(color: .black.opacity(scheme == .dark ? 0.5 : 0.14), radius: 15, y: 8)
    }
}
