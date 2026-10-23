import AppKit
import CoreGraphics
import SwiftUI
import TernCore

/// A transient, nonactivating glass card for locally extracted sign-in credentials. It floats just under the top of
/// the screen (below the notch or the menu bar), drops in on a spring and lifts away again.
@MainActor
final class LoginPopup: NSObject {
    private static weak var current: LoginPopup?
    private var panel: LoginPopupPanel?
    private var state: LoginCardState?
    private var dismissal: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var locked = false
    private var screensaver = false
    private var sleeping = false
    private var sessionInactive = false

    /// How long the card stays when nobody touches it; the pointer over it holds it open.
    private static let lifetime: Duration = .seconds(20)

    override init() {
        super.init()
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screenIsUnlocked",
                     "com.apple.screensaver.didstart", "com.apple.screensaver.didstop"] {
            distributed.addObserver(self, selector: #selector(sessionChanged(_:)), name: .init(name), object: nil)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification,
                     NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            workspace.addObserver(self, selector: #selector(sessionChanged(_:)), name: name, object: nil)
        }
    }

    deinit {
        DistributedNotificationCenter.default().removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        dismissal?.cancel()
        closing?.cancel()
    }

    func show(sender: String, account: String, credentials: [LoginCredential], perform: @escaping (LoginCredential) -> Void) {
        Self.current?.dismiss(animated: false)
        dismiss(animated: false)
        guard !credentials.isEmpty, mayShow,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let width = min(LoginCard.width, screen.frame.width - 32)
        let measure = NSHostingView(rootView: LoginPopupView(sender: sender, account: account, credentials: credentials,
            perform: { _ in }, dismiss: {}).frame(width: width))
        let state = LoginCardState(size: CGSize(width: width, height: measure.fittingSize.height))
        let view = LoginCardView(state: state, sender: sender, account: account, credentials: credentials, perform: { [weak self] credential in
            guard let self, self.mayShow else { self?.dismiss(); return }
            perform(credential)
            if case .code = credential {
                // The button says Copied for a moment before the card lifts away.
                state.copied = true
                self.scheduleDismissal(after: .milliseconds(900))
            } else {
                self.dismiss()
            }
        }, dismiss: { [weak self] in self?.dismiss() }, hovering: { [weak self] inside in
            // A card leaving under the pointer must not shorten the one that replaced it.
            guard let self, self.state === state, !state.copied else { return }
            if inside { self.dismissal?.cancel() } else { self.scheduleDismissal(after: .seconds(4)) }
        })

        let panel = LoginPopupPanel()
        panel.contentView = FirstMouseHostingView(rootView: view)
        let margin = LoginCard.margin
        let size = CGSize(width: state.size.width + margin * 2, height: state.size.height + margin * 2)
        let top = screen.frame.maxY - LoginCard.topInset(on: screen) - LoginCard.gap + margin
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: top - size.height,
                              width: size.width, height: size.height), display: true)
        self.panel = panel
        self.state = state
        Self.current = self
        panel.orderFrontRegardless()
        // One pass in the hidden pose first, so the card drops in rather than appearing already open.
        DispatchQueue.main.async { state.isOpen = true }
        scheduleDismissal(after: Self.lifetime)
    }

    func dismiss() { dismiss(animated: true) }

    private func dismiss(animated: Bool) {
        dismissal?.cancel()
        dismissal = nil
        if Self.current === self { Self.current = nil }
        guard let panel else { return }
        self.panel = nil
        let state = self.state
        self.state = nil
        closing?.cancel()
        guard animated, let state, state.isOpen else {
            panel.orderOut(nil)
            panel.contentView = nil
            return
        }
        state.isOpen = false
        closing = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(380))
            panel.orderOut(nil)
            panel.contentView = nil
        }
    }

    private func scheduleDismissal(after delay: Duration) {
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private var mayShow: Bool {
        guard !locked, !screensaver, !sleeping, !sessionInactive,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool != true
    }

    @objc private func sessionChanged(_ notification: Notification) {
        switch notification.name.rawValue {
        case "com.apple.screenIsLocked": locked = true
        case "com.apple.screenIsUnlocked": locked = false
        case "com.apple.screensaver.didstart": screensaver = true
        case "com.apple.screensaver.didstop": screensaver = false
        case NSWorkspace.willSleepNotification.rawValue: sleeping = true
        case NSWorkspace.didWakeNotification.rawValue: sleeping = false
        case NSWorkspace.sessionDidResignActiveNotification.rawValue: sessionInactive = true
        case NSWorkspace.sessionDidBecomeActiveNotification.rawValue: sessionInactive = false
        default: return
        }
        // Never restore a credential after waking or unlocking.
        dismiss(animated: false)
    }
}

/// The card's size, place and motion.
enum LoginCard {
    static let width: CGFloat = 372
    static let padding: CGFloat = 16
    /// Room around the card for its shadow and its drop; transparent, so clicks pass through.
    static let margin: CGFloat = 32
    /// Space between the card and the notch or menu bar above it.
    static let gap: CGFloat = 8
    /// Offscreen renders (tests, `--snapshot`) can't draw Liquid Glass, so they get the solid surface.
    @MainActor static var drawsGlass = true

    /// Liquid Glass is drawn (macOS 26, on screen); blurring glass while it fades makes it pop, so only the other
    /// surfaces blur on the way in and out.
    @MainActor static var usesGlass: Bool {
        guard drawsGlass else { return false }
        if #available(macOS 26, *) { return true }
        return false
    }

    /// The notch, or the menu bar on a screen without one; zero when the menu bar is hidden.
    @MainActor static func topInset(on screen: NSScreen) -> CGFloat {
        let notch = screen.safeAreaInsets.top
        return notch > 0 ? notch : max(0, screen.frame.maxY - screen.visibleFrame.maxY)
    }
}

@MainActor @Observable
final class LoginCardState {
    let size: CGSize
    var isOpen = false
    var copied = false

    init(size: CGSize) {
        self.size = size
    }
}

/// The card in its panel: hidden pose (narrower, shorter, blurred, a little higher) to open and back.
struct LoginCardView: View {
    let state: LoginCardState
    let sender: String
    let account: String
    let credentials: [LoginCredential]
    let perform: (LoginCredential) -> Void
    let dismiss: () -> Void
    let hovering: (Bool) -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = state.isOpen
        let moves = !reduceMotion
        let blurs = moves && !LoginCard.usesGlass
        LoginPopupView(sender: sender, account: account, credentials: credentials, copied: state.copied,
                       perform: perform, dismiss: dismiss)
            .frame(width: state.size.width, height: state.size.height, alignment: .top)
            .scaleEffect(x: open || !moves ? 1 : 0.86, y: open || !moves ? 1 : 0.7, anchor: .top)
            .scaleEffect(hovered && open && moves ? 1.012 : 1, anchor: .top)
            .offset(y: open || !moves ? 0 : -14)
            .blur(radius: open || !blurs ? 0 : 10)
            .opacity(open ? 1 : 0)
            .animation(moves ? (open ? Motion.floatingOpen : Motion.floatingClose) : Motion.reduced, value: open)
            .animation(Motion.floatingHover, value: hovered)
            .onHover { inside in
                hovered = inside
                hovering(inside)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Buttons answer the first click even though the panel never becomes key or activates Tern.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private final class LoginPopupPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        // Above the menu bar, so the card shows over full-screen apps too.
        level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3)
        hidesOnDeactivate = false
        // Stays up when Tern is hidden (⌘H): the card is for mail that arrives while you are in another app.
        canHide = false
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    /// The card may sit over the menu bar; the default would push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The card's content on its glass, always in the dark look so white text reads on any wallpaper.
/// Kept independent of the panel for offscreen snapshots.
struct LoginPopupView: View {
    let sender: String
    let account: String
    let credentials: [LoginCredential]
    var copied = false
    let perform: (LoginCredential) -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(sender: String, account: String, credentials: [LoginCredential], copied: Bool = false,
         perform: @escaping (LoginCredential) -> Void, dismiss: @escaping () -> Void) {
        self.sender = sender
        self.account = account
        self.credentials = credentials
        self.copied = copied
        self.perform = perform
        self.dismiss = dismiss
    }

    private var code: String? {
        credentials.lazy.compactMap { credential -> String? in
            if case .code(let value) = credential { value } else { nil }
        }.first
    }

    private var link: URL? {
        credentials.lazy.compactMap { credential -> URL? in
            if case .magicLink(let value) = credential { value } else { nil }
        }.first
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 8) {
                IconView(icon: .key, size: 14, color: .white.opacity(0.6))
                Text(sender)
                    .font(.ui(13, .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                // With several accounts the address is what tells the cards apart, so it keeps some room.
                Text(account)
                    .font(.ui(12))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(minWidth: 90, alignment: .leading)
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    IconView(icon: .close, size: 13, color: .white.opacity(0.7))
                }
                .buttonStyle(LoginCardButtonStyle(fill: .veil, shape: .circle))
                // The circle shows only on hover; the glyph lines up with the pills' right edge, and the row keeps
                // the text's height.
                .padding(.trailing, -7)
                .padding(.vertical, -5)
                .accessibilityLabel("Dismiss sign-in popup")
                .help("Dismiss")
            }
            if let code {
                HStack(spacing: 12) {
                    Text(Self.grouped(code))
                        .font(.numeric(30, .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .accessibilityLabel("Verification code \(code)")
                    Spacer(minLength: 8)
                    Button { perform(.code(code)) } label: {
                        HStack(spacing: 6) {
                            IconView(icon: copied ? .done : .copy, size: 14, color: .black)
                                .id(copied)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.4).combined(with: .opacity))
                            Text(copied ? "Copied" : "Copy")
                                .contentTransition(.opacity)
                        }
                        .font(.ui(13, .semibold))
                        .foregroundStyle(.black)
                        // Wide enough for Copied, so the pill never changes size.
                        .frame(minWidth: 76)
                        .animation(Motion.or(reduced: reduceMotion, Motion.confirm), value: copied)
                    }
                    .buttonStyle(LoginCardButtonStyle(fill: .solid, shape: .capsule))
                    .accessibilityLabel("Copy verification code \(code)")
                    .accessibilityValue(copied ? "Copied" : "")
                }
            }
            if let link {
                Button { perform(.magicLink(link)) } label: {
                    HStack(spacing: 8) {
                        IconView(icon: .link, size: 14, color: .white.opacity(0.75))
                        Text("Sign in")
                            .foregroundStyle(.white.opacity(0.92))
                        Text(link.host ?? "")
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        IconView(icon: .external, size: 13, color: .white.opacity(0.6))
                    }
                    .font(.ui(13, .medium))
                }
                .buttonStyle(LoginCardButtonStyle(fill: .veil, shape: .capsule))
                .accessibilityLabel("Open sign-in link for \(link.host ?? "website")")
            }
        }
        .padding(LoginCard.padding)
        .background(LoginCardSurface())
        .environment(\.colorScheme, .dark)
    }

    /// Six- and eight-digit codes read in halves, the way the email prints them; the copied code has no space.
    static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<middle]) \(code[middle...])"
    }
}

/// Liquid Glass with a dark tint, so the white text reads on any wallpaper. Without glass (before macOS 26, offscreen
/// renders) a dark material, and a solid surface when Reduce Transparency or Increase Contrast is on.
private struct LoginCardSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Radius.floatingCard, style: .continuous)
        surface(shape)
            .overlay(shape.strokeBorder(.white.opacity(contrast == .increased ? 0.3 : 0.1), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 18, y: 8)
    }

    @ViewBuilder private func surface(_ shape: RoundedRectangle) -> some View {
        if reduceTransparency || contrast == .increased || !LoginCard.drawsGlass {
            shape.fill(Color(white: 0.1))
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(.regular.tint(.black.opacity(0.45)), in: shape)
        } else {
            shape.fill(.ultraThinMaterial).overlay(shape.fill(.black.opacity(0.4)))
        }
    }
}

/// The card's buttons: a white capsule for the main action, a light wash for the rest. They lighten under the
/// pointer and give a little while held, then spring back.
private struct LoginCardButtonStyle: ButtonStyle {
    enum Fill { case solid, veil }
    enum Shape { case capsule, circle }
    let fill: Fill
    let shape: Shape

    func makeBody(configuration: Configuration) -> some View {
        LoginCardButton(configuration: configuration, fill: fill, shape: shape)
    }

    private struct LoginCardButton: View {
        let configuration: Configuration
        let fill: Fill
        let shape: Shape
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            let pressed = configuration.isPressed
            configuration.label
                .padding(.horizontal, shape == .capsule ? 14 : 0)
                .frame(width: shape == .circle ? 26 : nil, height: shape == .circle ? 26 : 32)
                .frame(maxWidth: shape == .capsule && fill == .veil ? .infinity : nil, alignment: .leading)
                .background(Capsule().fill(background(pressed: pressed)))
                .contentShape(Capsule())
                .scaleEffect(pressed && !reduceMotion ? (shape == .circle ? 0.95 : 0.97) : 1)
                .animation(pressed ? Motion.floatingPress : Motion.floatingRelease, value: pressed)
                // The hover wash fades in and goes at once.
                .animation(hovered ? .easeOut(duration: Motion.hover) : nil, value: hovered)
                .onHover { hovered = $0 }
        }

        private func background(pressed: Bool) -> Color {
            switch fill {
            case .solid: .white.opacity(pressed ? 0.85 : hovered ? 0.95 : 1)
            case .veil: .white.opacity(pressed ? 0.2 : hovered ? 0.16 : shape == .circle ? 0 : 0.1)
            }
        }
    }
}
