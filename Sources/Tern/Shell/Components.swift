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
        .accessibilityLabel(help, isEnabled: !help.isEmpty)
    }
}

// MARK: - Buttons

/// Text buttons use pill silhouettes, Geist Medium, and 28 pt (24 pt small) hit areas.
/// - `primary`: `ink` fill, `onInk` label. One per area at most.
/// - `secondary`: translucent wash and a two-tone glass edge over the parent material.
/// - `quiet`: no border; the `hover` fill appears under the pointer.
/// All three darken a step and shrink to 97 % while pressed (the shrink only, on a short spring; none under
/// Reduce Motion), show an `ink` ring when focused from the keyboard and drop to 50 % when disabled.
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
            let radius = (size == .small ? Theme.Control.small : Theme.Control.regular) / 2
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .font(.ui(size == .small ? 12 : 13, .medium))
                .lineLimit(1)
                .foregroundStyle(Color(kind == .primary ? Theme.onInk : Theme.text1))
                .padding(.horizontal, size == .small ? 10 : 12)
                .frame(height: size == .small ? Theme.Control.small : Theme.Control.regular)
                .background {
                    if kind == .secondary {
                        GlassControlFill(radius: radius, hovering: hovering && isEnabled,
                                         pressed: configuration.isPressed && isEnabled)
                    } else {
                        shape.fill(fill)
                        if kind == .primary {
                            shape.inset(by: 0.75).strokeBorder(
                                LinearGradient(colors: [.white.opacity(0.35), .clear],
                                               startPoint: .top, endPoint: .bottom), lineWidth: 0.5)
                        }
                    }
                }
                .focusRing(isFocused && isEnabled, shape: shape)
                .contentShape(shape)
                .pressScale(configuration.isPressed && isEnabled, to: 0.97)
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 && isEnabled }
        }

        private var fill: Color {
            let pressed = configuration.isPressed && isEnabled
            let hovering = hovering && isEnabled
            switch kind {
            case .primary:
                return Color(pressed ? Theme.inkPressed : hovering ? Theme.inkHover : Theme.ink)
            case .secondary, .quiet:
                return pressed ? Color(Theme.selected) : hovering ? Color(Theme.hover) : .clear
            }
        }
    }
}

/// Rounded toolbar controls with a neutral wash on hover and press. Prominent controls stay round and ink-filled.
struct IconButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledButton(configuration: configuration, prominent: prominent)
    }

    private struct StyledButton: View {
        let configuration: Configuration
        let prominent: Bool
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @Environment(\.colorScheme) private var colorScheme
        @State private var hovering = false

        var body: some View {
            if prominent {
                styledLabel(shape: Capsule())
            } else {
                styledLabel(shape: RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous))
            }
        }

        private func styledLabel<S: InsettableShape>(shape: S) -> some View {
            let pressed = configuration.isPressed && isEnabled
            let isHovering = hovering && isEnabled
            let hoverOpacity = colorScheme == .dark ? 0.075 : 0.05
            return configuration.label
                .background {
                    if prominent {
                        shape.fill(Color(pressed ? Theme.inkPressed : isHovering ? Theme.inkHover : Theme.ink))
                    } else if pressed || isHovering {
                        shape.fill(Color(Theme.text1).opacity(pressed ? 0.12 : hoverOpacity))
                    }
                }
                .focusRing(isFocused && isEnabled, shape: shape)
                .contentShape(Rectangle())
                .pressScale(pressed, to: 0.95)
                .opacity(isEnabled ? 1 : 0.5)
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
                .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.5)
                .onHover { hovering = $0 }
        }
    }
}

extension View {
    /// Press feedback: a short compression spring and softer release. Only the scale animates
    /// (fills stay instant), and a release mid-press retargets from where it is. Nothing under Reduce Motion.
    func pressScale(_ pressed: Bool, to scale: CGFloat) -> some View {
        modifier(PressScale(pressed: pressed, scale: scale))
    }

    /// Secondary controls reveal on hover, keyboard focus or accessibility focus; hidden controls ignore clicks.
    func hoverReveal(_ visible: Bool) -> some View {
        modifier(HoverReveal(visible: visible))
    }

    /// The keyboard focus ring: 1.5 px `ink` at 50 %, 2 px outside the control.
    func focusRing<S: InsettableShape>(_ visible: Bool, shape: S) -> some View {
        overlay(shape.inset(by: -2.5).strokeBorder(Color(Theme.ink).opacity(visible ? 0.5 : 0), lineWidth: 1.5))
    }
}

private struct PressScale: ViewModifier {
    let pressed: Bool
    let scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : pressed ? Motion.floatingPress : Motion.floatingRelease) {
            $0.scaleEffect(pressed && !reduceMotion ? scale : 1)
        }
    }
}

private struct HoverReveal: ViewModifier {
    let visible: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool
    @AccessibilityFocusState private var accessibilityFocused: Bool

    func body(content: Content) -> some View {
        let shown = visible || focused || accessibilityFocused
        content
            .focused($focused)
            .accessibilityFocused($accessibilityFocused)
            .allowsHitTesting(shown)
            .animation(visible && !focused && !accessibilityFocused
                       ? Motion.or(reduced: reduceMotion, .easeOut(duration: Motion.hover)) : nil) {
                $0.opacity(shown ? 1 : 0)
            }
    }
}

/// A `text3` label for work in progress ("Writing…"): a soft light passes over it every 1.4 s while it shows.
/// Still under Reduce Motion.
struct WaitingText: View {
    let text: String
    var size: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var phase: CGFloat = 0

    var body: some View {
        let label = Text(text).font(.ui(size))
        label
            .foregroundStyle(Color(Theme.text3))
            .overlay {
                if !reduceMotion {
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.35), .init(color: Color(Theme.text1), location: 0.5),
                                .init(color: .clear, location: 0.65)],
                        startPoint: UnitPoint(x: -1.5 + phase * 2.5, y: 0.5),
                        endPoint: UnitPoint(x: 1 + phase * 2.5, y: 0.5))
                        .mask(label)
                        .onAppear {
                            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) { phase = 1 }
                        }
                }
            }
            .accessibilityLabel(text)
    }
}

/// A shortcut key in Geist with tabular figures, e.g. the `/` in the search field or `⌘K` in the palette.
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
