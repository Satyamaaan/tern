import AppKit
import SwiftUI

enum GlassSurfaceKind { case floating, chrome, sidebar }

extension View {
    /// Glass belongs behind controls, never around their rendered content or inside reusable mail rows.
    func glassSurface(radius: CGFloat = Theme.Radius.card, kind: GlassSurfaceKind = .floating) -> some View {
        background(GlassSurface(radius: radius, kind: kind).allowsHitTesting(false).accessibilityHidden(true))
    }
}

struct GlassSurface: View {
    /// Offscreen snapshots exercise the accessibility fallback; live captures exercise the compositor.
    static var forceSolid = false
    let radius: CGFloat
    let kind: GlassSurfaceKind
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var solid: Bool { Self.forceSolid || reduceTransparency || contrast == .increased }
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: radius, style: .continuous) }

    var body: some View {
        ZStack {
            if kind == .floating {
                // A separate silhouette casts the shadow without flattening the live material or text.
                shape.fill(.black.opacity(scheme == .dark ? 0.22 : 0.08))
                    .blur(radius: 12)
                    .offset(y: 8)
                    .padding(1)
            }
            material
                .clipShape(shape)
            if kind == .floating {
                shape.strokeBorder(Color(Theme.hairlineStrong).opacity(solid ? 1 : 0.65), lineWidth: 0.5)
                shape.inset(by: 0.75).strokeBorder(
                    LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.18 : 0.85),
                                            .white.opacity(scheme == .dark ? 0.025 : 0.12)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: solid ? 0 : 0.5)
            }
        }
    }

    @ViewBuilder private var material: some View {
        if solid {
            Color(kind == .sidebar ? Theme.sidebar : Theme.raised)
        } else if WindowBackdropView.isAvailable {
            WindowBackdrop()
                .overlay(Color(kind == .sidebar ? Theme.sidebar : Theme.raised)
                    .opacity(kind == .sidebar ? 0.72 : 0.82))
        } else if kind == .sidebar {
            DesktopMaterial()
                .overlay(Color(Theme.sidebar).opacity(scheme == .dark ? 0.32 : 0.22))
        } else if kind == .floating {
            if #available(macOS 26.0, *) {
                Color.clear.glassEffect(.clear, in: shape)
                    .overlay(Color(Theme.raised).opacity(scheme == .dark ? 0.72 : 0.78))
            } else {
                shape.fill(.ultraThinMaterial)
                    .overlay(Color(Theme.raised).opacity(0.16))
            }
        } else {
            DesktopMaterial()
                .overlay(Color(Theme.raised).opacity(scheme == .dark ? 0.48 : 0.6))
        }
    }
}

/// A lightweight control wash over the parent material. It never creates another backdrop layer.
struct GlassControlFill: View {
    var radius: CGFloat = 14
    var highlighted = false
    var hovering = false
    var pressed = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let solid = GlassSurface.forceSolid || reduceTransparency || contrast == .increased
        let opacity: Double = scheme == .dark
            ? (pressed ? 0.20 : hovering || highlighted ? 0.14 : 0.08)
            : (pressed ? 0.10 : hovering || highlighted ? 0.065 : 0.035)
        shape
            .fill(solid ? Color(highlighted || pressed ? Theme.selectedFocus : hovering ? Theme.hover : Theme.raised)
                  : Color(scheme == .dark ? NSColor.white : Theme.ink).opacity(opacity))
            .overlay(shape.strokeBorder(Color(Theme.hairlineStrong).opacity(solid ? 1 : 0.55), lineWidth: 0.5))
            .overlay(shape.inset(by: 0.75).strokeBorder(
                LinearGradient(colors: [.white.opacity(solid ? 0 : scheme == .dark ? 0.22 : 0.9), .clear],
                               startPoint: .top, endPoint: .bottom), lineWidth: 0.5))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

/// The sidebar samples the desktop through the window. Mail and editor canvases remain opaque.
private struct DesktopMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
