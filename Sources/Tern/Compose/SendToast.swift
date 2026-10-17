import AppKit
import Observation
import SwiftUI

/// The undo pill after Send ("Sending in 5 s · Undo"), floating at the bottom centre of the main
/// window. Used when the shell doesn't take `AppServices.showSendUndo`. `z` (outside text fields) or
/// ⌘Z undoes while it is up.
@MainActor
enum SendToast {
    private static var panel: ToastPanel?
    private static var monitor: Any?
    private static var dismissal: Task<Void, Never>?

    static func show(_ notice: SendUndoNotice, over window: NSWindow?) {
        present(ToastState(message: notice.message, deadline: notice.deadline, undo: notice.undo), duration: notice.duration, over: window)
    }

    /// A short message without an action ("Already sent").
    static func show(message: String, over window: NSWindow?) {
        present(ToastState(message: message, deadline: nil, undo: nil), duration: 2, over: window)
    }

    private static func present(_ state: ToastState, duration: TimeInterval, over window: NSWindow?) {
        dismiss()
        let host = window.flatMap { $0 is ComposerWindow ? nil : $0 }
            ?? NSApp.windows.first { $0.isVisible && !($0 is ComposerWindow) && !($0 is NSPanel) && $0.isMainWindow }
            ?? NSApp.windows.first { $0.isVisible && !($0 is ComposerWindow) && !($0 is NSPanel) }
        let panel = ToastPanel(state: state) { dismiss() }
        let size = panel.contentView?.fittingSize ?? NSSize(width: 240, height: 40)
        let area = host?.frame ?? NSScreen.main?.visibleFrame ?? .zero
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 24, width: size.width, height: size.height), display: true)
        if let host { host.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
        self.panel = panel

        if state.undo != nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                // z or ⌘Z, unless a text field has focus (there ⌘Z undoes typing).
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let typing = NSApp.keyWindow?.firstResponder is NSTextView
                guard !typing, event.charactersIgnoringModifiers?.lowercased() == "z",
                      modifiers.isEmpty || modifiers == .command else { return event }
                state.performUndo()
                dismiss()
                return nil
            }
        }
        dismissal = Task {
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    static func dismiss() {
        dismissal?.cancel()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let panel {
            panel.parent?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
    }
}

@MainActor
@Observable
final class ToastState {
    let message: String
    let deadline: Date?
    let undo: (@MainActor () -> Void)?
    private var used = false

    init(message: String, deadline: Date?, undo: (@MainActor () -> Void)?) {
        self.message = message
        self.deadline = deadline
        self.undo = undo
    }

    func performUndo() {
        guard !used else { return }
        used = true
        undo?()
    }
}

final class ToastPanel: NSPanel {
    init(state: ToastState, dismiss: @escaping @MainActor () -> Void) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        contentView = NSHostingView(rootView: SendToastView(state: state, dismiss: dismiss))
    }

    override var canBecomeKey: Bool { false }
}

/// "Sending in 4 s · Undo  z": the pill itself.
struct SendToastView: View {
    let state: ToastState
    let dismiss: @MainActor () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                Text(text(at: context.date))
                    .font(.ui(13))
                    .foregroundStyle(Color(Theme.text1))
                    .monospacedDigit()
                if state.undo != nil {
                    Text("·").foregroundStyle(Color(Theme.text3))
                    Button {
                        state.performUndo()
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Text("Undo").font(.ui(13, .medium)).foregroundStyle(Color(Theme.accentInk))
                            Text("Z")
                                .font(.mono(11))
                                .foregroundStyle(Color(Theme.text3))
                                .frame(width: 16, height: 16)
                                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(Theme.hairlineStrong)))
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Capsule().fill(Color(Theme.raised)))
            .overlay(Capsule().strokeBorder(Color(Theme.hairline)))
            .shadow(color: .black.opacity(0.14), radius: 15, y: 8)
            .padding(.horizontal, 30)
            .padding(.vertical, 24)
        }
        .fixedSize()
    }

    private func text(at now: Date) -> String {
        guard let deadline = state.deadline else { return state.message }
        let seconds = Int(ceil(deadline.timeIntervalSince(now)))
        return seconds > 0 ? "\(state.message) in \(seconds) s" : "\(state.message)…"
    }
}
