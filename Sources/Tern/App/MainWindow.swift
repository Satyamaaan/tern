import AppKit
import SwiftUI

/// The main window: no visible title bar, our own background, traffic lights moved into the sidebar
/// header at (16, 18).
final class MainWindow: NSWindow {
    static let defaultSize = NSSize(width: 1320, height: 840)
    static let minimumSize = NSSize(width: 960, height: 600)
    /// Height of the sidebar and list headers the traffic lights sit in.
    static let headerHeight: CGFloat = 52
    static let trafficLightOrigin = CGPoint(x: 16, y: 18)

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        title = "Tern"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // The list scrolls under the title bar; macOS would draw its own line there. Date headers have theirs.
        titlebarSeparatorStyle = .none
        isReleasedWhenClosed = false
        minSize = Self.minimumSize
        backgroundColor = Theme.bg
        collectionBehavior.insert(.fullScreenPrimary)
        tabbingMode = .disallowed
        self.contentView = contentView
        if !setFrameUsingName("TernMain") { center() }
        setFrameAutosaveName("TernMain")

        for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSWindow.didExitFullScreenNotification, NSWindow.didBecomeMainNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(placeTrafficLights), name: name, object: self)
        }
        placeTrafficLights()
    }

    override func layoutIfNeeded() {
        super.layoutIfNeeded()
        placeTrafficLights()
    }

    /// Moves the close / minimize / zoom buttons into the 52 px header. Full screen keeps the system layout.
    @objc func placeTrafficLights() {
        guard !styleMask.contains(.fullScreen),
              let close = standardWindowButton(.closeButton),
              let titlebar = close.superview,
              let container = titlebar.superview
        else { return }
        let height = Self.headerHeight
        let containerFrame = NSRect(x: 0, y: frame.height - height, width: frame.width, height: height)
        if container.frame != containerFrame { container.frame = containerFrame }
        if titlebar.frame != container.bounds { titlebar.frame = container.bounds }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for (index, type) in buttons.enumerated() {
            guard let button = standardWindowButton(type) else { continue }
            let origin = NSPoint(
                x: Self.trafficLightOrigin.x + CGFloat(index) * 20,
                y: titlebar.isFlipped ? Self.trafficLightOrigin.y : height - Self.trafficLightOrigin.y - button.frame.height)
            if button.frame.origin != origin { button.setFrameOrigin(origin) }
        }
    }
}

/// Lets an empty header area drag the window, since the title bar is hidden behind our own content.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { DragView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
                if action == "Minimize" { window?.performMiniaturize(nil) } else if action != "None" { window?.performZoom(nil) }
                return
            }
            window?.performDrag(with: event)
        }
    }
}
