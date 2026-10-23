import AppKit
import TernCore

/// Explicit user gestures only: detection itself never touches the clipboard, browser or mail labels.
@MainActor
enum LoginActions {
    static func perform(_ credential: LoginCredential, window: NSWindow? = nil) {
        switch credential {
        case .code(let code): copy(code)
        case .magicLink(let url): confirmOpen(url, window: window)
        }
    }

    static func copy(_ code: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, .init("org.nspasteboard.ConcealedType"),
                                 .init("org.nspasteboard.TransientType")], owner: nil)
        pasteboard.setString(code, forType: .string)
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        pasteboard.setData(Data(), forType: .init("org.nspasteboard.TransientType"))
    }

    private static func confirmOpen(_ url: URL, window: NSWindow?) {
        guard url.scheme?.lowercased() == "https", RemoteDestination.allows(url), let host = url.host else { return }
        let alert = NSAlert()
        alert.messageText = "Open sign-in link on \(host)?"
        alert.informativeText = "Only continue if you requested this sign-in and trust the sender. Tern has not verified this website."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Link")
        if let window {
            alert.beginSheetModal(for: window) { response in
                if response == .alertSecondButtonReturn { NSWorkspace.shared.open(url) }
            }
        } else if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }
}
