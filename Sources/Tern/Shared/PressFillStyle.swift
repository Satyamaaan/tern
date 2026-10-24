import AppKit
import SwiftUI

/// Rows and tabs that act on a click: a fill under the pointer, a stronger one the moment the mouse goes down
/// (instant, no motion, no scale), and the action on mouse-up.
struct PressFillStyle: ButtonStyle {
    var radius: CGFloat = Theme.Radius.control
    /// The fill at rest (a selected row), if any.
    var rest: NSColor?
    /// The fill under the pointer; nil keeps the rest fill.
    var hover: NSColor? = Theme.hover
    var pressed: NSColor = Theme.selected

    func makeBody(configuration: Configuration) -> some View {
        Styled(configuration: configuration, style: self)
    }

    private struct Styled: View {
        let configuration: Configuration
        let style: PressFillStyle
        @Environment(\.isEnabled) private var isEnabled
        @Environment(\.isFocused) private var isFocused
        @State private var hovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: style.radius, style: .continuous)
            configuration.label
                .background(shape.fill(fill))
                .focusRing(isFocused && isEnabled, shape: shape)
                .contentShape(Rectangle())
                .opacity(isEnabled ? 1 : 0.5)
                .onHover { hovering = $0 && isEnabled }
        }

        private var fill: Color {
            if isEnabled && configuration.isPressed { return Color(style.pressed) }
            if isEnabled && hovering, let hover = style.hover { return Color(hover) }
            return style.rest.map { Color($0) } ?? .clear
        }
    }
}
