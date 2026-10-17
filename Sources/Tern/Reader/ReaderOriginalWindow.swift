import AppKit
import TernCore

/// "Show original": the headers we store and both bodies, unrendered, in a monospaced window.
@MainActor
enum ReaderOriginalWindow {
    private static var open: [NSWindow] = []

    static func show(_ message: MailMessage, attachments: [MailAttachment]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Original — \(message.subject.isEmpty ? "(no subject)" : message.subject)"
        window.isReleasedWhenClosed = false
        window.backgroundColor = Theme.raised
        let scroll = NSTextView.scrollableTextView()
        if let text = scroll.documentView as? NSTextView {
            text.isEditable = false
            text.isRichText = false
            text.font = Theme.mono(12)
            text.textColor = Theme.text1
            text.backgroundColor = Theme.raised
            text.textContainerInset = NSSize(width: 16, height: 16)
            text.string = source(message, attachments: attachments)
        }
        window.contentView = scroll
        window.center()
        window.makeKeyAndOrderFront(nil)
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { open.removeAll { $0 === window } }
        }
    }

    static func source(_ message: MailMessage, attachments: [MailAttachment]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        func list(_ people: [Participant]) -> String {
            people.map { $0.name.isEmpty ? $0.email : "\($0.name) <\($0.email)>" }.joined(separator: ", ")
        }
        var lines: [String] = []
        func add(_ name: String, _ value: String?) {
            if let value, !value.isEmpty { lines.append("\(name): \(value)") }
        }
        add("From", list([message.from]))
        add("To", list(message.toList))
        add("Cc", list(message.ccList))
        add("Bcc", list(message.bccList))
        add("Reply-To", list(message.replyTo))
        add("Date", formatter.string(from: message.date))
        add("Subject", message.subject)
        add("Message-ID", message.rfcMessageId)
        add("In-Reply-To", message.inReplyTo)
        add("References", message.refs)
        add("List-Unsubscribe", message.listUnsubscribe)
        add("List-Unsubscribe-Post", message.listUnsubscribePost)
        add("X-Gmail-Labels", message.labelIds.joined(separator: ", "))
        add("X-Gmail-Ids", "message \(message.id), thread \(message.threadId), account \(message.accountId)")
        var output = lines.joined(separator: "\n")
        output += "\n\nTern keeps the headers above and the decoded parts below, not the raw MIME source.\n"
        for attachment in attachments {
            output += "\nPart \(attachment.partId): \(attachment.mimeType), \(attachment.filename), \(attachment.size) bytes"
            if let id = attachment.contentId { output += ", Content-ID <\(id)>" }
        }
        if let text = message.bodyText { output += "\n\n——— text/plain ———\n\n" + text }
        if let html = message.bodyHtml { output += "\n\n——— text/html ———\n\n" + html }
        if message.bodyState == .metadata { output += "\n\n(The body hasn't been downloaded yet.)" }
        return output
    }
}
