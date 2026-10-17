import AppKit
import TernCore

/// Which messages may load remote images. The From header can be forged, so it never decides alone:
/// your own mail is recognised by Gmail's SENT label, a sender you chose never counts in Spam, and
/// "Load images" on a message covers only that message.
struct ReaderTrust: Sendable {
    /// Lowercased senders the user chose "Always load images" for.
    var senders: Set<String> = []
    /// Messages the user loaded images in once.
    var messages: Set<MessageKey> = []
    /// False when the reader can't block remote loads; then no message gets its images.
    var remoteImages = true

    func allows(_ message: MailMessage) -> Bool {
        guard remoteImages else { return false }
        return Self.isOwn(message) || messages.contains(message.key) || trustsSender(of: message)
    }

    /// Images load for this message only, so the reader offers to always load them from its sender.
    func loadedOnce(_ message: MailMessage) -> Bool {
        remoteImages && messages.contains(message.key) && !Self.isOwn(message) && !trustsSender(of: message)
            && !message.labelIds.contains(SystemLabel.spam)
    }

    private func trustsSender(of message: MailMessage) -> Bool {
        senders.contains(message.fromEmail.lowercased()) && !message.labelIds.contains(SystemLabel.spam)
    }

    /// Sent or drafted from this account, by Gmail's labels rather than the From address.
    static func isOwn(_ message: MailMessage) -> Bool {
        message.labelIds.contains(SystemLabel.sent) || message.isDraft
    }
}

/// What the payload needs besides the thread itself.
struct ReaderContext {
    var accountEmails: Set<String>
    var accountColorIndex: Int
    /// Gmail label id → name, for the thread's account.
    var labelNames: [String: String]
    var trust: ReaderTrust
    var summary: [String: Any]
    var now = Date()

    func isMe(_ email: String) -> Bool { accountEmails.contains(email.lowercased()) }
}

/// Builds the dictionary `Tern.render` draws, and decides which messages start expanded.
enum ReaderPayload {
    /// The latest unread message, else the last one that isn't a draft.
    static func targetMessage(_ detail: ThreadDetail) -> MailMessage? {
        let sent = detail.messages.filter { !$0.isDraft }
        return sent.last(where: \.isUnread) ?? sent.last ?? detail.messages.last
    }

    /// Bodies up to this many bytes are sanitized while building the payload (a few milliseconds);
    /// bigger ones that aren't cached yet are sanitized off the main thread and arrive after the first paint.
    static let inlineSanitizeLimit = 100_000

    /// The payload, and the messages whose bodies are sanitized off the main thread: open ones still
    /// loading (`loading`), and the collapsed ones (`deferred`).
    static func make(_ detail: ThreadDetail, context: ReaderContext)
        -> (payload: [String: Any], loading: [MailMessage], deferred: [MailMessage]) {
        let target = targetMessage(detail)
        var messages: [[String: Any]] = []
        var loading: [MailMessage] = []
        var deferred: [MailMessage] = []
        for message in detail.messages {
            let expanded = message.id == target?.id || detail.messages.count == 1
            var item = messagePayload(message, detail: detail, context: context)
            item["expanded"] = expanded
            item["target"] = message.id == target?.id
            let trusted = isTrusted(message, context)
            if expanded, let body = ReaderBodies.shared.cachedBody(for: message, trusted: trusted)
                ?? (bodyLength(message) <= inlineSanitizeLimit ? ReaderBodies.shared.body(for: message, trusted: trusted) : nil) {
                item["body"] = bodyPayload(body)
            } else if expanded {
                // The page shows the snippet and waits for `setBodies` instead of asking for it.
                item["bodyLoading"] = true
                loading.append(message)
            } else {
                deferred.append(message)
            }
            messages.append(item)
        }
        let payload: [String: Any] = [
            "key": detail.thread.key.description,
            "subject": detail.thread.subject.isEmpty ? (detail.messages.first?.subject ?? "") : detail.thread.subject,
            "chips": chips(detail, context: context),
            "summary": context.summary,
            "messages": messages,
        ]
        return (payload, loading, deferred)
    }

    static func header(_ detail: ThreadDetail, context: ReaderContext) -> [String: Any] {
        ["key": detail.thread.key.description, "chips": chips(detail, context: context), "summary": context.summary]
    }

    static func isTrusted(_ message: MailMessage, _ context: ReaderContext) -> Bool {
        context.trust.allows(message)
    }

    static func bodyPayload(_ mail: SanitizedMail) -> [String: Any] {
        ["html": mail.html, "css": mail.css, "bodyStyle": mail.bodyStyle, "mode": mail.mode.rawValue, "blocked": mail.blockedRemoteCount]
    }

    /// Identifies the rendered content of a thread; when it is unchanged, only the header is refreshed.
    static func signature(_ detail: ThreadDetail, context: ReaderContext) -> String {
        var parts = [detail.thread.key.description]
        for message in detail.messages {
            parts.append("\(message.id):\(message.bodyState.rawValue):\(bodyLength(message)):\(message.isDraft):\(isTrusted(message, context)):\(context.trust.loadedOnce(message))")
        }
        parts.append(String(detail.attachments.values.reduce(0) { $0 + $1.count }))
        return parts.joined(separator: "|")
    }

    static func bodyLength(_ message: MailMessage) -> Int {
        (message.bodyHtml?.utf8.count ?? 0) + (message.bodyText?.utf8.count ?? 0)
    }

    // MARK: Pieces

    private static func messagePayload(_ message: MailMessage, detail: ThreadDetail, context: ReaderContext) -> [String: Any] {
        let mine = context.isMe(message.fromEmail)
        let name = mine ? "me" : message.from.displayName
        let recipients = message.toList + message.ccList
        var toNames = recipients.map { context.isMe($0.email) ? "me" : $0.firstName }
        if let me = toNames.firstIndex(of: "me"), me > 0 { toNames.insert(toNames.remove(at: me), at: 0) }
        var toLine = "to " + (toNames.isEmpty ? "undisclosed recipients" : toNames.prefix(3).joined(separator: ", "))
        if toNames.count > 3 { toLine += " +\(toNames.count - 3)" }

        var details: [[String]] = [["From", formatted(message.from)]]
        if !message.toList.isEmpty { details.append(["To", message.toList.map(formatted).joined(separator: ", ")]) }
        if !message.ccList.isEmpty { details.append(["Cc", message.ccList.map(formatted).joined(separator: ", ")]) }
        if !message.replyTo.isEmpty, message.replyTo.map(\.email) != [message.fromEmail] {
            details.append(["Reply-To", message.replyTo.map(formatted).joined(separator: ", ")])
        }
        details.append(["Date", message.date.formatted(date: .complete, time: .shortened)])

        let attachments = (detail.attachments[message.id] ?? [])
            .filter { !($0.isInline && $0.contentId != nil) }
            .map { attachment -> [String: Any] in
                [
                    "id": attachment.id, "name": attachment.filename.isEmpty ? "Attachment" : attachment.filename,
                    "size": ByteCountFormatter.string(fromByteCount: Int64(attachment.size), countStyle: .file),
                    "kind": attachment.mimeType.hasPrefix("image/") ? "image" : "file",
                ]
            }

        return [
            "id": message.id,
            "from": name,
            "email": message.fromEmail.lowercased(),
            "initials": initials(message.from),
            "hue": hue(for: message.fromEmail, mine: mine, context: context),
            "toLine": toLine,
            "details": details,
            "date": shortDate(message.date, now: context.now),
            "dateLong": longDate(message.date, now: context.now),
            "dateFull": message.date.formatted(date: .complete, time: .standard),
            "snippet": snippet(message),
            "unread": message.isUnread,
            "draft": message.isDraft,
            "imagesAllowed": isTrusted(message, context),
            "imagesOnce": context.trust.loadedOnce(message),
            "bodyVersion": "\(message.bodyState.rawValue):\(bodyLength(message))",
            "attachments": attachments,
        ]
    }

    private static func chips(_ detail: ThreadDetail, context: ReaderContext) -> [[String: Any]] {
        var chips: [[String: Any]] = []
        if let ai = detail.ai {
            if ai.needsReply { chips.append(["text": "Needs reply", "kind": "needs"]) }
            if ai.category != .people, ai.category != .other {
                chips.append(["text": categoryName(ai.category), "kind": "cat", "color": "var(--cat-\(ai.category.rawValue))"])
            }
        }
        for project in detail.projects {
            chips.append(["text": project.name, "kind": "project", "color": ReaderResources.hex(Theme.projectColor(project.colorIndex))])
        }
        for id in detail.thread.labelIds where !SystemLabel.all.contains(id) && !id.hasPrefix("CATEGORY_") {
            if let name = context.labelNames[id] { chips.append(["text": name, "kind": "label"]) }
        }
        if let until = detail.snoozedUntil {
            chips.append(["text": "Snoozed · \(SnoozeOption.detailText(until, now: context.now))", "kind": "label"])
        }
        return chips
    }

    static func categoryName(_ category: MailCategory) -> String {
        switch category {
        case .people: "People"
        case .notification: "Notification"
        case .newsletter: "Newsletter"
        case .receipt: "Receipt"
        case .calendar: "Calendar"
        case .promotion: "Promotion"
        case .security: "Security"
        case .other: "Other"
        }
    }

    private static func snippet(_ message: MailMessage) -> String {
        if message.isDraft, message.snippet.isEmpty { return message.bodyText ?? "" }
        let text = message.snippet.isEmpty ? (message.bodyText ?? "") : message.snippet
        return String(text.replacingOccurrences(of: "\n", with: " ").prefix(200))
    }

    private static func formatted(_ participant: Participant) -> String {
        participant.name.isEmpty ? participant.email : "\(participant.name) <\(participant.email)>"
    }

    static func initials(_ participant: Participant) -> String {
        let source = participant.name.isEmpty ? participant.email : participant.name
        let words = source.split(whereSeparator: { $0 == " " || $0 == "." || $0 == "-" || $0 == "_" || $0 == "@" })
            .filter { $0.first?.isLetter == true }
        let letters = words.prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "?" : letters.joined()
    }

    private static func hue(for email: String, mine: Bool, context: ReaderContext) -> String {
        if mine { return ReaderResources.hex(Theme.accountColor(context.accountColorIndex)) }
        var hash: UInt32 = 2_166_136_261
        for byte in email.lowercased().utf8 { hash = (hash ^ UInt32(byte)) &* 16_777_619 }
        let hues: [UInt32] = [0x4F7CAC, 0x8A6FB3, 0x3E9A86, 0x8F7F62, 0xB05C7A, 0x6B7F4A, 0x5E6B7A, 0x7A6A5C]
        return ReaderResources.hex(Theme.rgb(hues[Int(hash % UInt32(hues.count))]))
    }

    /// "10:42" today, "Tue" this week, "Oct 12" this year, "Oct 12 '25" before.
    static func shortDate(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return date.formatted(date: .omitted, time: .shortened) }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day,
           days < 7, days > 0 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(.dateTime.month(.abbreviated).day()) }
        return date.formatted(.dateTime.month(.abbreviated).day()) + " '" + date.formatted(.dateTime.year(.twoDigits))
    }

    /// The expanded header's date: time today, otherwise date and time.
    static func longDate(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) {
            return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) + ", " + time
        }
        return shortDate(date, now: now, calendar: calendar)
    }
}

/// Sanitized message bodies, kept across thread switches so reopening a thread costs nothing.
/// Safe to use from any thread.
final class ReaderBodies: @unchecked Sendable {
    static let shared = ReaderBodies()

    private struct Key: Hashable {
        var accountId: String
        var messageId: String
        var version: String
        var trusted: Bool
    }

    private let lock = NSLock()
    private var storage: [Key: SanitizedMail] = [:]
    private var order: [Key] = []
    private var bytes = 0
    /// Bodies are kept until they add up to this many bytes of markup.
    private let budget = 48 * 1_024 * 1_024

    /// The sanitized body if it is already cached.
    func cachedBody(for message: MailMessage, trusted: Bool) -> SanitizedMail? {
        let key = Self.key(message, trusted: trusted)
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    private static func key(_ message: MailMessage, trusted: Bool) -> Key {
        Key(accountId: message.accountId, messageId: message.id,
            version: "\(message.bodyState.rawValue):\(ReaderPayload.bodyLength(message))", trusted: trusted)
    }

    func body(for message: MailMessage, trusted: Bool) -> SanitizedMail {
        let key = Self.key(message, trusted: trusted)
        lock.lock()
        if let cached = storage[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()
        let mail = Self.sanitize(message, trusted: trusted)
        lock.lock()
        if storage.updateValue(mail, forKey: key) == nil {
            order.append(key)
            bytes += Self.cost(mail)
            while bytes > budget, order.count > 1 {
                let old = order.removeFirst()
                if let evicted = storage.removeValue(forKey: old) { bytes -= Self.cost(evicted) }
            }
        }
        lock.unlock()
        return mail
    }

    private static func cost(_ mail: SanitizedMail) -> Int { mail.html.utf8.count + mail.css.utf8.count + 256 }

    static func sanitize(_ message: MailMessage, trusted: Bool) -> SanitizedMail {
        if let html = message.bodyHtml, !html.isEmpty {
            let account = message.accountId, id = message.id
            let options = MailSanitizer.Options(
                allowRemoteImages: trusted, remoteImageURL: ReaderRemoteImages.readerURL(for:)
            ) { contentId in
                MailSanitizer.contentIdURL(accountId: account, messageId: id, contentId: contentId)
            }
            return MailSanitizer.sanitize(html: html, options: options)
        }
        if let text = message.bodyText, !text.isEmpty { return PlainTextMail.html(text) }
        var placeholder = PlainTextMail.html(message.snippet)
        if message.bodyState == .metadata {
            // Older mail is stored without its body; sync fetches it when the thread opens.
            placeholder.html = "<div class=\"tern-plain\" style=\"opacity:.6\">" + placeholder.html + "</div>"
                + "<div style=\"margin-top:10px;font-size:12px;opacity:.5\">Loading message…</div>"
        }
        return placeholder
    }
}
