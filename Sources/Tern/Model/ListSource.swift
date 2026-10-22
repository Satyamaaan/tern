import Foundation
import GRDB
import TernCore

extension InboxTab {
    var title: String {
        switch self {
        case .primary: "Primary"
        case .promotions: "Promotions"
        case .social: "Social"
        case .updates: "Updates"
        case .forums: "Forums"
        }
    }
}

/// What the list column reads. One value per screen state; the list observation restarts when it changes.
struct ListSource: Hashable, Sendable {
    var mailbox: Mailbox
    /// Gmail's tab, when the mailbox is the inbox and its tabs are on; nil is the whole inbox.
    var tab: InboxTab?

    /// Inbox slice for inbox-backed lists.
    var inboxFilter: InboxFilter? {
        guard case .inbox = mailbox.kind else { return nil }
        return InboxFilter(accountId: mailbox.accountId, tab: tab)
    }

    /// Lists sorted by something other than date get no date groups.
    var groupsByDate: Bool {
        if [.snoozed, .due, .waitingOn, .iOwe].contains(mailbox.kind) { return false }
        return true
    }

    func fetch(_ db: Database, limit: Int) throws -> [ThreadRow] {
        guard let filter = inboxFilter else {
            return try MailStore.fetchThreadRows(db, in: mailbox, limit: limit, before: nil)
        }
        return try MailStore.fetchInboxRows(db, filter, limit: limit)
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
        case .archive: "Archive"
        case .spam: "Spam"
        case .trash: "Trash"
        case .label: "Label"
        case .project: "Project"
        case .category(let category): category.title
        case .due: "Due"
        case .waitingOn: "Due"
        case .iOwe: "Due"
        case .needsReply: "Needs reply"
        }
    }

    /// The one line shown when the list is empty.
    var emptyLine: String {
        switch self {
        case .inbox: "Nothing needs you."
        case .starred: "No starred mail."
        case .important: "Nothing marked important."
        case .snoozed: "No snoozed mail."
        case .sent: "Nothing sent yet."
        case .drafts: "No drafts."
        case .allMail: "No mail here yet."
        case .archive: "Nothing archived yet."
        case .spam: "No spam. Nice."
        case .trash: "Trash is empty."
        case .label: "No mail with this label."
        case .project: "No mail in this project yet."
        case .category: "Nothing in this tab."
        case .due, .waitingOn: "Things you owe and are waiting on will appear here."
        case .iOwe: "Things you owe and are waiting on will appear here."
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
