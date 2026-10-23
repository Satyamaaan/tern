import AppKit
import CoreGraphics
import SwiftUI
import TernCore

/// A transient, nonactivating surface for locally extracted sign-in credentials. It grows out of the notch (or the
/// top edge of a screen without one), drops down with the code, and folds back up into it.
@MainActor
final class LoginPopup: NSObject {
    private static weak var current: LoginPopup?
    private var panel: LoginPopupPanel?
    private var state: LoginIslandState?
    private var dismissal: Task<Void, Never>?
    private var closing: Task<Void, Never>?
    private var locked = false
    private var screensaver = false
    private var sleeping = false
    private var sessionInactive = false

    /// How long the card stays down when nobody touches it; the pointer over it holds it open.
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
        let notch = LoginIslandGeometry(screen: screen)
        let width = min(LoginIslandGeometry.openWidth, screen.frame.width - 32)
        guard width > notch.closed.width || !notch.hasNotch else { return }

        let measure = NSHostingView(rootView: LoginPopupView(sender: sender, account: account, credentials: credentials,
            topInset: notch.closed.height, perform: { _ in }, dismiss: {}).frame(width: width))
        let open = CGSize(width: width, height: measure.fittingSize.height)
        let state = LoginIslandState(closed: notch.closed, open: open)
        let view = LoginIsland(state: state, sender: sender, account: account, credentials: credentials, perform: { [weak self] credential in
            guard let self, self.mayShow else { self?.dismiss(); return }
            perform(credential)
            if case .code = credential {
                // The button says Copied for a moment before the card folds away.
                state.copied = true
                self.scheduleDismissal(after: .milliseconds(700))
            } else {
                self.dismiss()
            }
        }, dismiss: { [weak self] in self?.dismiss() }, hovering: { [weak self] inside in
            // A card folding away under the pointer must not shorten the one that replaced it.
            guard let self, self.state === state, !state.copied else { return }
            if inside { self.dismissal?.cancel() } else { self.scheduleDismissal(after: .seconds(4)) }
        })

        let panel = LoginPopupPanel()
        let host = FirstMouseHostingView(rootView: view)
        panel.contentView = host
        let size = CGSize(width: open.width + LoginIslandGeometry.margin * 2, height: open.height + LoginIslandGeometry.margin)
        panel.setFrame(NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true)
        self.panel = panel
        self.state = state
        Self.current = self
        panel.orderFrontRegardless()
        // One pass at the notch's size first, so the drop starts from the notch rather than appearing already open.
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
            try? await Task.sleep(for: .milliseconds(320))
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

/// Where the card grows from: the notch, or a notch-wide slit at the top edge of a screen without one.
struct LoginIslandGeometry {
    static let openWidth: CGFloat = 372
    /// Room around the card for its shadow; transparent, so clicks pass through.
    static let margin: CGFloat = 24
    let hasNotch: Bool
    let closed: CGSize

    init(screen: NSScreen) {
        let inset = screen.safeAreaInsets.top
        if inset > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            hasNotch = true
            closed = CGSize(width: max(0, screen.frame.width - left.width - right.width), height: inset)
        } else {
            hasNotch = false
            closed = CGSize(width: 200, height: 0)
        }
    }
}

@MainActor @Observable
final class LoginIslandState {
    let closed: CGSize
    let open: CGSize
    var isOpen = false
    var copied = false

    init(closed: CGSize, open: CGSize) {
        self.closed = closed
        self.open = open
    }
}

/// The black shape between the notch's size and the card's, with the card's content fading in once it has room.
struct LoginIsland: View {
    let state: LoginIslandState
    let sender: String
    let account: String
    let credentials: [LoginCredential]
    let perform: (LoginCredential) -> Void
    let dismiss: () -> Void
    let hovering: (Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let open = state.isOpen
        let size = open || reduceMotion ? state.open : state.closed
        LoginPopupView(sender: sender, account: account, credentials: credentials, topInset: state.closed.height,
                       copied: state.copied, perform: perform, dismiss: dismiss)
            .frame(width: state.open.width, height: state.open.height, alignment: .top)
            .opacity(open ? 1 : 0)
            .blur(radius: open || reduceMotion ? 0 : 6)
            .scaleEffect(open || reduceMotion ? 1 : 0.92, anchor: .top)
            .animation(Motion.or(reduced: reduceMotion, open ? Motion.ease(0.24).delay(0.08) : Motion.ease(0.1)), value: open)
            .frame(width: size.width, height: size.height, alignment: .top)
            .clipShape(LoginIslandShape(radius: open ? 22 : 10))
            .background(LoginIslandShape(radius: open ? 22 : 10).fill(.black)
                .shadow(color: .black.opacity(open ? 0.35 : 0), radius: 16, y: 6))
            .opacity(reduceMotion && !open ? 0 : 1)
            .animation(reduceMotion ? Motion.reduced
                       : open ? .spring(response: 0.42, dampingFraction: 0.74) : .spring(response: 0.3, dampingFraction: 1),
                       value: open)
            .onHover(perform: hovering)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.colorScheme, .dark)
    }
}

/// Flat along the top edge with small outward flares where it meets the bezel, rounded below: the notch's own outline.
private struct LoginIslandShape: Shape {
    var radius: CGFloat
    var animatableData: CGFloat {
        get { radius }
        set { radius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let flare: CGFloat = min(8, rect.height / 2)
        let r = min(radius, rect.height / 2, rect.width / 2 - flare)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX - flare, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX + flare, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + flare), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + flare))
        path.addQuadCurve(to: CGPoint(x: rect.minX - flare, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.closeSubpath()
        return path
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
        // Above the menu bar, so the card can join the notch.
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
    /// The card sits over the menu bar; the default would push it below.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The open card's content, white on the island's black. Kept independent of the panel for offscreen snapshots.
struct LoginPopupView: View {
    let sender: String
    let account: String
    let credentials: [LoginCredential]
    /// The notch's height: content starts below it.
    var topInset: CGFloat = 0
    var copied = false
    let perform: (LoginCredential) -> Void
    let dismiss: () -> Void

    init(sender: String, account: String, credentials: [LoginCredential], topInset: CGFloat = 0, copied: Bool = false,
         perform: @escaping (LoginCredential) -> Void, dismiss: @escaping () -> Void) {
        self.sender = sender
        self.account = account
        self.credentials = credentials
        self.topInset = topInset
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
                IconView(icon: .key, size: 14, color: .white.opacity(0.55))
                Text(sender)
                    .font(.ui(13, .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                Text(account)
                    .font(.ui(12))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Button(action: dismiss) {
                    IconView(icon: .close, size: 14, color: .white.opacity(0.55))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
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
                            Text(copied ? "Copied" : "Copy")
                        }
                        .font(.ui(13, .semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .background(Capsule().fill(.white))
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Copy verification code \(code)")
                }
            }
            if let link {
                Button { perform(.magicLink(link)) } label: {
                    HStack(spacing: 8) {
                        IconView(icon: .link, size: 14, color: .white.opacity(0.7))
                        Text("Sign in")
                            .foregroundStyle(.white)
                        Text(link.host ?? "")
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        IconView(icon: .external, size: 13, color: .white.opacity(0.5))
                    }
                    .font(.ui(13, .medium))
                    .padding(.horizontal, 12)
                    .frame(height: 32)
                    .background(Capsule().fill(.white.opacity(0.12)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open sign-in link for \(link.host ?? "website")")
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, topInset + 10)
        .padding(.bottom, 16)
        .background(.black)
        .environment(\.colorScheme, .dark)
    }

    /// Six- and eight-digit codes read in halves, the way the email prints them; the copied code has no space.
    static func grouped(_ code: String) -> String {
        guard code.count == 6 || code.count == 8 else { return code }
        let middle = code.index(code.startIndex, offsetBy: code.count / 2)
        return "\(code[..<middle]) \(code[middle...])"
    }
}
