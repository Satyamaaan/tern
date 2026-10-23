import AppKit
import SwiftUI

/// The small floating glass card Tern uses for its own prompts (updates, moving to Applications):
/// the app icon at the top left beside a title and a
/// line of detail; optional content below, aligned with the text; buttons on the right. A `quiet` card (errors)
/// sets its title as plain `text2` instead of a semibold heading.
struct AppCard<Content: View, Buttons: View>: View {
    static var width: CGFloat { 380 }
    /// Where text starts: past the 44 pt icon and its 12 pt gap.
    static var textInset: CGFloat { 56 }

    let title: String
    var detail: String?
    var quiet = false
    /// False drops the button row (a card that only reports progress).
    var hasButtons = true
    @ViewBuilder var content: () -> Content
    @ViewBuilder var buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: AppIcon.image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 44, height: 44)
                    .padding(-2)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(quiet ? .ui(13) : .ui(14, .semibold))
                        .lineSpacing(quiet ? 2 : 0)
                        .foregroundStyle(Color(quiet ? Theme.text2 : Theme.text1))
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        Text(detail)
                            .font(.ui(12.5))
                            .lineSpacing(2)
                            .foregroundStyle(Color(Theme.text2))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                // A lone line sits level with the icon's centre; more lines start at its top.
                .frame(minHeight: 40, alignment: .leading)
            }
            content()
                .padding(.leading, Self.textInset)
            if hasButtons {
                HStack(spacing: 8) {
                    Spacer(minLength: 0)
                    buttons()
                }
            }
        }
        .padding(20)
        .frame(width: Self.width, alignment: .leading)
        .glassSurface()
    }
}

extension AppCard where Content == EmptyView {
    init(title: String, detail: String? = nil, quiet: Bool = false, @ViewBuilder buttons: @escaping () -> Buttons) {
        self.init(title: title, detail: detail, quiet: quiet, hasButtons: true, content: { EmptyView() }, buttons: buttons)
    }
}

/// A thin `ink` progress line on an `inkSoft` track. Nil animates a short segment back and forth.
struct ThinProgress: View {
    var fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color(Theme.inkSoft))
                if let fraction {
                    // Linear, so reports arriving many times a second read as one steady fill.
                    Capsule().fill(Color(Theme.ink))
                        .frame(width: max(2, width * min(max(fraction, 0), 1)))
                        .animation(.linear(duration: 0.25), value: fraction)
                } else if reduceMotion {
                    // Reduce Motion: the segment stays put and breathes (opacity 0.5 ↔ 1 over 1.6 s).
                    TimelineView(.animation(minimumInterval: 1 / 30)) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        Capsule().fill(Color(Theme.ink))
                            .frame(width: width * 0.28)
                            .offset(x: width * 0.36)
                            .opacity(0.75 + 0.25 * cos(phase * 2 * .pi))
                    }
                } else {
                    TimelineView(.animation) { context in
                        let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                        let travel = (1 - cos(phase * 2 * .pi)) / 2
                        Capsule().fill(Color(Theme.ink))
                            .frame(width: width * 0.28)
                            .offset(x: (width * 0.72) * travel)
                    }
                }
            }
        }
        .frame(height: 3)
        .clipShape(Capsule())
    }
}

/// The app's icon: the bundle's AppIcon.icns, or build/AppIcon.icns when running unbundled from
/// `swift build` (snapshots).
enum AppIcon {
    @MainActor static let image: NSImage = {
        if let icon = Bundle.main.image(forResource: "AppIcon") { return icon }
        let built = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../../build/AppIcon.icns").standardized
        return NSImage(contentsOf: built) ?? NSApp.applicationIconImage
    }()
}

/// A borderless, transparent window that floats an `AppCard`: it can take the keyboard (Return and Esc reach the
/// card's buttons), moves by its background, keeps the card's top edge in place as the card grows or shrinks,
/// and leaves room around the card for its shadow.
@MainActor
final class CardPanel: NSPanel {
    /// Room for the overlay shadow (radius 15, 8 down) around the card.
    static let margin = NSEdgeInsets(top: 24, left: 32, bottom: 44, right: 32)

    init<V: View>(_ view: V) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        // Tern's own entrance and exit (present, dismiss), not AppKit's alert animation.
        animationBehavior = .none
        let margin = Self.margin
        let root = view
            .padding(EdgeInsets(top: margin.top, leading: margin.left, bottom: margin.bottom, trailing: margin.right))
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { $0.size } action: { [weak self] size in
                self?.fit(size)
            }
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        contentView = hosting
        fit(hosting.fittingSize)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Esc closes the card the way its quiet button would.
    var onCancel: (() -> Void)?

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Resizes to the card, keeping the top edge where it is (and where it will rest, while it moves).
    private func fit(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        if let resting {
            self.resting = NSPoint(x: resting.x, y: resting.y + frame.height - size.height)
        }
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// Puts the card near the top of the main window, riding above it as a child window (so clicking the window
    /// doesn't bury it), or in the upper middle of the screen when no window is up.
    private func place() {
        let size = frame.size
        if let host = NSApp.windows.first(where: { $0 is MainWindow && $0.isVisible && !$0.isMiniaturized }) {
            let area = host.frame
            setFrameOrigin(NSPoint(x: area.midX - size.width / 2, y: area.maxY - 96 - size.height))
            host.addChildWindow(self, ordered: .above)
        } else if let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.midX - size.width / 2, y: screen.minY + screen.height * 0.62 - size.height / 2))
        }
    }

    /// Bumped by every present and dismiss, so a dismiss's late `orderOut` never hides a card shown again since.
    private var generation = 0
    /// Where the card rests on screen, kept while it fades out so a present can bring it back there.
    private var resting: NSPoint?
    private(set) var isLeaving = false

    /// On screen and not on its way out.
    var isShown: Bool { isVisible && !isLeaving }

    /// Shows the card. `takesFocus` only for something the user just asked for (a check, a prompt at launch): a
    /// card that arrives on its own must not catch the keys of someone typing, where Return would press its
    /// primary button.
    ///
    /// It fades in and settles 6 pt into place (180 ms, house curve); a card on its way out turns back from where
    /// it is. Reduce Motion: an 80 ms fade.
    func present(takesFocus: Bool) {
        generation += 1
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isVisible {
            place()
            resting = frame.origin
            alphaValue = 0
            if !reduce { setFrameOrigin(NSPoint(x: frame.minX, y: frame.minY + 6)) }
        }
        isLeaving = false
        if takesFocus && NSApp.isActive { makeKeyAndOrderFront(nil) } else { orderFront(nil) }
        // Already resting (a new phase of a card on screen): nothing to move.
        guard let target = resting else { alphaValue = 1; return }
        let current = generation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0.08 : 0.18
            context.timingFunction = reduce ? CAMediaTimingFunction(name: .easeOut) : Motion.timing
            animator().alphaValue = 1
            if frame.origin != target { animator().setFrameOrigin(target) }
        } completionHandler: {
            MainActor.assumeIsolated { if self.generation == current { self.resting = nil } }
        }
    }

    /// Hides the card and lets it go: it fades and lifts 4 pt (120 ms; an 80 ms fade with Reduce Motion), then
    /// orders out.
    func dismiss() {
        generation += 1
        let current = generation
        guard isVisible else {
            parent?.removeChildWindow(self)
            orderOut(nil)
            return
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !isLeaving { resting = frame.origin }
        isLeaving = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduce ? 0.08 : Motion.exit
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = 0
            if !reduce, let resting { animator().setFrameOrigin(NSPoint(x: resting.x, y: resting.y + 4)) }
        } completionHandler: {
            // Holds the panel until it is out, even if its owner has let it go.
            MainActor.assumeIsolated {
                guard self.generation == current else { return }
                self.isLeaving = false
                self.parent?.removeChildWindow(self)
                self.orderOut(nil)
                self.alphaValue = 1
                self.resting = nil
            }
        }
    }
}
