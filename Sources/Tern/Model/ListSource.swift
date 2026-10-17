import Foundation
import GRDB
import TernCore

/// The split-inbox tabs. "Important" is people, needs reply, calendar, security and anything the
/// classifier hasn't seen yet, so new mail is never hidden behind a tab.
enum InboxSplit: String, CaseIterable, Identifiable, Sendable {
    case important, people, notifications, newsletters, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .important: "Important"
        case .people: "People"
        case .notifications: "Notifications"
        case .newsletters: "Newsletters"
        case .other: "Other"
        }
    }

    func filter(accountId: String?) -> InboxFilter {
        switch self {
        case .important:
            InboxFilter(accountId: accountId, categories: [.people, .calendar, .security], includeUncategorized: true, includeNeedsReply: true)
        case .people: InboxFilter(accountId: accountId, categories: [.people])
        case .notifications: InboxFilter(accountId: accountId, categories: [.notification])
        case .newsletters: InboxFilter(accountId: accountId, categories: [.newsletter])
        case .other: InboxFilter(accountId: accountId, categories: [.receipt, .promotion, .other])
        }
    }
}

/// What the list column reads. One value per screen state; the list observation restarts when it changes.
struct ListSource: Hashable, Sendable {
    var mailbox: Mailbox
    /// The split tab, when the mailbox is the inbox and split inbox is on.
    var split: InboxSplit?

    /// Inbox slice for inbox-backed lists.
    var inboxFilter: InboxFilter? {
        guard case .inbox = mailbox.kind else { return nil }
        return split?.filter(accountId: mailbox.accountId) ?? InboxFilter(accountId: mailbox.accountId)
    }

    /// Inbox and the Important tab show threads waiting on you first, above the waterline.
    var needsReplyFirst: Bool {
        guard case .inbox = mailbox.kind else { return false }
        return split == nil || split == .important
    }

    /// Lists sorted by something other than date get no date groups.
    var groupsByDate: Bool {
        if case .snoozed = mailbox.kind { return false }
        return true
    }

    func fetch(_ db: Database, limit: Int) throws -> [ThreadRow] {
        guard let filter = inboxFilter else {
            return try MailStore.fetchThreadRows(db, in: mailbox, limit: limit, before: nil)
        }
        guard needsReplyFirst else { return try MailStore.fetchInboxRows(db, filter, limit: limit) }
        var waiting = filter
        waiting.needsReply = .only
        var rest = filter
        rest.needsReply = .exclude
        let first = try MailStore.fetchInboxRows(db, waiting, limit: limit)
        guard first.count < limit else { return first }
        return first + (try MailStore.fetchInboxRows(db, rest, limit: limit - first.count))
    }
}

extension Mailbox.Kind {
    var title: String {
        switch self {
        case .inbox: "Inbox"
        case .starred: "Starred"
        case .important: "Important"
        case .snoozed: "Snoozed"
        case .sent: "Sent"
        case .drafts: "Drafts"
        case .allMail: "All mail"
        case .spam: "Spam"
        case .trash: "Trash"
        case .label: "Label"
        case .project: "Project"
        case .category(let category): category.title
        case .needsReply: "Needs reply"
        }
    }

    /// One serif line shown when the list is empty.
    var emptyLine: String {
        switch self {
        case .inbox: "Nothing needs you."
        case .starred: "No starred mail."
        case .important: "Nothing marked important."
        case .snoozed: "No snoozed mail."
        case .sent: "Nothing sent yet."
        case .drafts: "No drafts."
        case .allMail: "No mail here yet."
        case .spam: "No spam. Nice."
        case .trash: "Trash is empty."
        case .label: "No mail with this label."
        case .project: "No mail in this project yet."
        case .category: "Nothing in this tab."
        case .needsReply: "No one is waiting on you."
        }
    }
}

extension MailCategory {
    var title: String {
        switch self {
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

    /// Categories worth a chip in the list; people and other are the default and stay quiet.
    var showsChip: Bool { self != .people && self != .other }
}
