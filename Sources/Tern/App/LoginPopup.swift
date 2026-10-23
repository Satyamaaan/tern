import AppKit
import CoreGraphics
import SwiftUI
import TernCore

/// A transient, nonactivating surface for locally extracted sign-in credentials.
@MainActor
final class LoginPopup: NSObject {
    private static weak var current: LoginPopup?
    private var panel: LoginPopupPanel?
    private var dismissal: Task<Void, Never>?
    private var locked = false
    private var screensaver = false
    private var sleeping = false
    private var sessionInactive = false

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
    }

    func show(sender: String, account: String, credentials: [LoginCredential], perform: @escaping (LoginCredential) -> Void) {
        Self.current?.dismiss()
        dismiss()
        guard !credentials.isEmpty, mayShow,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main else { return }
        let width = min(360, screen.visibleFrame.width - 32)
        guard width > 0 else { return }
        let view = LoginPopupView(sender: sender, account: account, credentials: credentials, perform: { [weak self] credential in
            guard let self, self.mayShow else { self?.dismiss(); return }
            self.dismiss()
            perform(credential)
        }, dismiss: { [weak self] in self?.dismiss() })
        let host = NSHostingView(rootView: view.frame(width: width))
        let panel = LoginPopupPanel()
        panel.contentView = host
        let size = host.fittingSize
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.maxX - size.width - 16, y: area.minY + 16,
                              width: size.width, height: size.height), display: true)
        self.panel = panel
        Self.current = self
        panel.orderFrontRegardless()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
        if Self.current === self { Self.current = nil }
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
        dismiss()
    }
}

private final class LoginPopupPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        sharingType = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Kept independent of the panel for offscreen light/dark and long-content snapshots.
struct LoginPopupView: View {
    let sender: String
    let account: String
    let credentials: [LoginCredential]
    let perform: (LoginCredential) -> Void
    let dismiss: () -> Void

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
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Sign-in details")
                        .font(.ui(14, .semibold))
                        .foregroundStyle(Color(Theme.text1))
                    Text(sender)
                        .font(.ui(13, .medium))
                        .foregroundStyle(Color(Theme.text1))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(account)
                        .font(.ui(12))
                        .foregroundStyle(Color(Theme.text2))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: dismiss) {
                    IconView(icon: .close, size: 16, color: Color(Theme.text2))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(IconButtonStyle())
                .accessibilityLabel("Dismiss login popup")
                .help("Dismiss")
            }
            if let code {
                Button { use(.code(code)) } label: {
                    HStack(spacing: 8) {
                        Text(code).font(.numeric(20, .semibold))
                            .lineLimit(1).minimumScaleFactor(0.65)
                        Spacer(minLength: 8)
                        IconView(icon: .copy, size: 16, color: Color(Theme.onInk))
                        Text("Copy")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TernButtonStyle(.primary))
                .accessibilityLabel("Copy verification code \(code)")
            }
            if let link {
                Button { use(.magicLink(link)) } label: {
                    HStack(spacing: 8) {
                        IconView(icon: .link, size: 16, color: Color(Theme.text2))
                        Text("Sign in")
                        Spacer(minLength: 4)
                        Text(link.host ?? "Sign-in link")
                            .lineLimit(1).truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(TernButtonStyle(.secondary))
                .accessibilityLabel("Open sign-in link for \(link.host ?? "website")")
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous).fill(Color(Theme.raised)))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
            .strokeBorder(Color(Theme.hairlineStrong), lineWidth: 1))
    }

    private func use(_ credential: LoginCredential) {
        dismiss()
        perform(credential)
    }
}
