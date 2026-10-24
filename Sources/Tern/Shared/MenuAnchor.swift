import AppKit
import SwiftUI

/// A passive background view that anchors native menus without a mouse event.
struct MenuAnchor: NSViewRepresentable {
    let view: AnchorView

    func makeNSView(context: Context) -> AnchorView {
        view.setAccessibilityElement(false)
        return view
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        /// AppKit owns tracking, dismissal and focus; the callback keeps hover-only triggers visible.
        func popUp(_ menu: NSMenu, onTrackingChange: ((Bool) -> Void)? = nil) {
            guard window != nil else { return }
            let point = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4)
            onTrackingChange?(true)
            defer { onTrackingChange?(false) }
            menu.popUp(positioning: nil, at: point, in: self)
        }
    }
}
