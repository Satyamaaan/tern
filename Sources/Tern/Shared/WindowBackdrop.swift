import AppKit
import SwiftUI

/// Lightly blur the desktop without the opaque tint imposed by system materials.
/// CABackdropLayer and CAFilter are private APIs; callers must keep a public-material fallback.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowBackdropView { WindowBackdropView() }
    func updateNSView(_ view: WindowBackdropView, context: Context) {}
}

final class WindowBackdropView: NSView {
    private static let layerType = NSClassFromString("CABackdropLayer") as? CALayer.Type
    private static let filterType = NSClassFromString("CAFilter") as? NSObject.Type
    static var isAvailable: Bool { layerType != nil && filterType != nil }
    private let backdrop: CALayer?

    init() {
        backdrop = Self.layerType?.init()
        super.init(frame: .zero)
        wantsLayer = true
        guard let backdrop, let filterType = Self.filterType,
              let blur = filterType.perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject else { return }
        blur.setValue(6.0, forKey: "inputRadius")
        blur.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.setValue(true, forKey: "windowServerAware")
        backdrop.filters = [blur]
        layer?.addSublayer(backdrop)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        backdrop?.setValue(window?.backingScaleFactor ?? 2, forKey: "scale")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        CATransaction.commit()
    }
}
