import Foundation
import GRDB

// Every record stores dates as seconds since 1970 so they can be indexed and compared in SQL.
public protocol TernRecord: Codable, FetchableRecord, PersistableRecord, Sendable {}

extension TernRecord {
    public static func databaseDateEncodingStrategy(for column: String) -> DatabaseDateEncodingStrategy {
        .timeIntervalSince1970
    }
    public static func databaseDateDecodingStrategy(for column: String) -> DatabaseDateDecodingStrategy {
        .timeIntervalSince1970
    }
}

// MARK: - Shared value types

public struct Participant: Codable, Hashable, Sendable {
    public var name: String
    public var email: String

    public init(name: String = "", email: String) {
        self.name = name
        self.email = email
    }

    public var displayName: String { name.isEmpty ? email : name }
    public var firstName: String {
        guard !name.isEmpty else { return email.split(separator: "@").first.map(String.init) ?? email }
        return name.split(separator: " ").first.map(String.init) ?? name
    }
}

/// Identifies a conversation. Gmail ids are only unique within one account.
public struct ThreadKey: Hashable, Codable, Sendable, CustomStringConvertible {
    public var accountId: String
    public var threadId: String

    public init(accountId: String, threadId: String) {
        self.accountId = accountId
        self.threadId = threadId
    }

    public var description: String { "\(accountId)/\(threadId)" }
}

public struct MessageKey: Hashable, Codable, Sendable {
    public var accountId: String
    public var messageId: String

    public init(accountId: String, messageId: String) {
        self.accountId = accountId
        self.messageId = messageId
    }
}

/// Gmail's built-in label ids.
public enum SystemLabel {
    public static let inbox = "INBOX"
    public static let unread = "UNREAD"
    public static let starred = "STARRED"
    public static let important = "IMPORTANT"
    public static let sent = "SENT"
    public static let draft = "DRAFT"
    public static let spam = "SPAM"
    public static let trash = "TRASH"
    public static let chat = "CHAT"
    public static let categoryPersonal = "CATEGORY_PERSONAL"
    public static let categorySocial = "CATEGORY_SOCIAL"
    public static let categoryPromotions = "CATEGORY_PROMOTIONS"
    public static let categoryUpdates = "CATEGORY_UPDATES"
    public static let categoryForums = "CATEGORY_FORUMS"

    public static let all: Set<String> = [
        inbox, unread, starred, important, sent, draft, spam, trash, chat,
        categoryPersonal, categorySocial, categoryPromotions, categoryUpdates, categoryForums,
    ]
}

// MARK: - Accounts and labels

public enum SyncState: String, Codable, Sendable, DatabaseValueConvertible {
    case new, backfilling, live, error, needsAuth
}

public struct Account: TernRecord, Identifiable, Hashable {
    public static let databaseTableName = "account"

    /// The lowercased email address.
    public var id: String
    public var email: String
    public var displayName: String
    public var colorIndex: Int
    public var sortOrder: Int
    /// Last Gmail historyId fully applied to the local store.
    public var historyId: String?
    public var syncState: SyncState
    public var syncError: String?
    /// messages.list page token to resume the backfill of older mail.
    public var backfillPageToken: String?
    public var backfillDone: Bool
    public var lastSyncAt: Date?
    public var createdAt: Date

    public init(
        email: String, displayName: String = "", colorIndex: Int = 0, sortOrder: Int = 0,
        historyId: String? = nil, syncState: SyncState = .new, syncError: String? = nil,
        backfillPageToken: String? = nil, backfillDone: Bool = false, lastSyncAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = email.lowercased()
        self.email = email
        self.displayName = displayName
        self.colorIndex = colorIndex
        self.sortOrder = sortOrder
        self.historyId = historyId
        self.syncState = syncState
        self.syncError = syncError
        self.backfillPageToken = backfillPageToken
        self.backfillDone = backfillDone
        self.lastSyncAt = lastSyncAt
        self.createdAt = createdAt
    }
}

public struct MailLabel: TernRecord, Hashable {
    public static let databaseTableName = "label"

    public var accountId: String
    public var id: String
    public var name: String
    /// "system" or "user".
    public var type: String
    public var colorBackground: String?
    public var colorText: String?
    public var hidden: Bool

    public init(
        accountId: String, id: String, name: String, type: String = "user",
        colorBackground: String? = nil, colorText: String? = nil, hidden: Bool = false
    ) {
        self.accountId = accountId
        self.id = id
        self.name = name
        self.type = type
        self.colorBackground = colorBackground
        self.colorText = colorText
        self.hidden = hidden
    }

    public var isSystem: Bool { type == "system" }
}

// MARK: - Messages and threads

public struct MailMessage: TernRecord, Hashable {
    public static let databaseTableName = "message"

    public var accountId: String
    public var id: String
    public var threadId: String
    public var historyId: String?
    /// Gmail internalDate.
    public var date: Date
    public var fromName: String
    public var fromEmail: String
    public var toList: [Participant]
    public var ccList: [Participant]
    public var bccList: [Participant]
    public var replyTo: [Participant]
    public var subject: String
    public var snippet: String
    /// Plain text body (from text/plain, or derived from HTML). Nil until the body is fetched.
    public var bodyText: String?
    /// Original, unsanitized HTML body. Nil when the message has none or it isn't fetched yet.
    public var bodyHtml: String?
    public var bodyState: BodyState
    public var labelIds: [String]
    public var isUnread: Bool
    public var isStarred: Bool
    public var isDraft: Bool
    public var isFromMe: Bool
    public var hasAttachments: Bool
    /// RFC 822 Message-ID header, kept for reply threading.
    public var rfcMessageId: String?
    public var inReplyTo: String?
    public var refs: String?
    public var listUnsubscribe: String?
    public var listUnsubscribePost: String?
    public var sizeEstimate: Int
    /// Derived by MailStore on write for full-text search. Leave empty when building records.
    public var searchSender: String = ""
    public var searchRecipients: String = ""

    public enum BodyState: Int, Codable, Sendable, DatabaseValueConvertible {
        case metadata = 0, full = 1
    }

    public init(
        accountId: String, id: String, threadId: String, historyId: String? = nil, date: Date,
        fromName: String = "", fromEmail: String = "", toList: [Participant] = [],
        ccList: [Participant] = [], bccList: [Participant] = [], replyTo: [Participant] = [],
        subject: String = "", snippet: String = "", bodyText: String? = nil, bodyHtml: String? = nil,
        bodyState: BodyState = .metadata, labelIds: [String] = [], isFromMe: Bool = false,
        hasAttachments: Bool = false, rfcMessageId: String? = nil, inReplyTo: String? = nil,
        refs: String? = nil, listUnsubscribe: String? = nil, listUnsubscribePost: String? = nil,
        sizeEstimate: Int = 0
    ) {
        self.accountId = accountId
        self.id = id
        self.threadId = threadId
        self.historyId = historyId
        self.date = date
        self.fromName = fromName
        self.fromEmail = fromEmail
        self.toList = toList
        self.ccList = ccList
        self.bccList = bccList
        self.replyTo = replyTo
        self.subject = subject
        self.snippet = snippet
        self.bodyText = bodyText
        self.bodyHtml = bodyHtml
        self.bodyState = bodyState
        self.labelIds = labelIds
        self.isUnread = labelIds.contains(SystemLabel.unread)
        self.isStarred = labelIds.contains(SystemLabel.starred)
        self.isDraft = labelIds.contains(SystemLabel.draft)
        self.isFromMe = isFromMe || labelIds.contains(SystemLabel.sent)
        self.hasAttachments = hasAttachments
        self.rfcMessageId = rfcMessageId
        self.inReplyTo = inReplyTo
        self.refs = refs
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.sizeEstimate = sizeEstimate
    }

    public var key: MessageKey { MessageKey(accountId: accountId, messageId: id) }
    public var threadKey: ThreadKey { ThreadKey(accountId: accountId, threadId: threadId) }
    public var from: Participant { Participant(name: fromName, email: fromEmail) }

    /// Keeps the label-derived flags in step after editing `labelIds`.
    public mutating func syncFlagsFromLabels() {
        isUnread = labelIds.contains(SystemLabel.unread)
        isStarred = labelIds.contains(SystemLabel.starred)
        isDraft = labelIds.contains(SystemLabel.draft)
        if labelIds.contains(SystemLabel.sent) { isFromMe = true }
    }
}

public struct MailAttachment: TernRecord, Hashable, Identifiable {
    public static let databaseTableName = "attachment"

    public var accountId: String
    public var messageId: String
    public var partId: String
    /// Gmail attachment id. Nil when the data was inline in the message payload.
    public var attachmentId: String?
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Content-ID without angle brackets, for `cid:` inline images.
    public var contentId: String?
    public var isInline: Bool
    /// Cached file once downloaded.
    public var localPath: String?

    public init(
        accountId: String, messageId: String, partId: String, attachmentId: String? = nil,
        filename: String, mimeType: String, size: Int, contentId: String? = nil,
        isInline: Bool = false, localPath: String? = nil
    ) {
        self.accountId = accountId
        self.messageId = messageId
        self.partId = partId
        self.attachmentId = attachmentId
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentId = contentId
        self.isInline = isInline
        self.localPath = localPath
    }

    public var id: String { "\(accountId)/\(messageId)/\(partId)" }
}

/// One conversation, derived from its messages by `MailStore.refreshThreads`. Never edit it directly.
public struct MailThread: TernRecord, Hashable, Identifiable {
    public static let databaseTableName = "thread"

    public var accountId: String
    public var id: String
    public var subject: String
    public var snippet: String
    /// Newest non-draft message date (or newest draft when the thread has only drafts).
    public var lastDate: Date
    /// Newest message not sent by the account owner.
    public var lastInboundDate: Date?
    public var messageCount: Int
    public var unreadCount: Int
    public var isStarred: Bool
    public var isImportant: Bool
    public var hasAttachments: Bool
    public var hasDraft: Bool
    /// Distinct senders in order of first appearance; the account owner is included with their address.
    public var participants: [Participant]
    /// Union of all message labels.
    public var labelIds: [String]

    public var key: ThreadKey { ThreadKey(accountId: accountId, threadId: id) }
}

// MARK: - AI classification, projects, snooze

/// Split-inbox buckets. Assigned by rules first, refined by the AI classifier.
public enum MailCategory: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    /// A real person wrote to you.
    case people
    /// Automated notifications from tools (GitHub, Linear, Vercel, Slack digests…).
    case notification
    case newsletter
    case receipt
    case calendar
    case promotion
    /// Sign-in codes, password resets, security alerts.
    case security
    case other
}

public struct ThreadAI: TernRecord, Hashable {
    public static let databaseTableName = "thread_ai"

    public var accountId: String
    public var threadId: String
    public var category: MailCategory
    public var needsReply: Bool
    /// 0 = low … 3 = urgent.
    public var priority: Int
    /// One line, shown in the list when present.
    public var summary: String?
    /// "rules", "codex", "claude"…
    public var source: String
    /// Message count when classified; reclassify when the thread grows.
    public var messageCount: Int
    public var classifiedAt: Date

    public init(
        accountId: String, threadId: String, category: MailCategory, needsReply: Bool = false,
        priority: Int = 1, summary: String? = nil, source: String = "rules", messageCount: Int,
        classifiedAt: Date = Date()
    ) {
        self.accountId = accountId
        self.threadId = threadId
        self.category = category
        self.needsReply = needsReply
        self.priority = priority
        self.summary = summary
        self.source = source
        self.messageCount = messageCount
        self.classifiedAt = classifiedAt
    }
}

/// A cross-account bucket, e.g. a client or a product. Threads join by rules, by hand, or by AI.
public struct Project: TernRecord, Hashable, Identifiable {
    public static let databaseTableName = "project"

    public var id: String
    public var name: String
    public var colorIndex: Int
    /// SF Symbol name or a single emoji.
    public var icon: String?
    public var sortOrder: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString, name: String, colorIndex: Int = 0, icon: String? = nil,
        sortOrder: Int = 0, createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.colorIndex = colorIndex
        self.icon = icon
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

public struct ProjectRule: TernRecord, Hashable, Identifiable {
    public static let databaseTableName = "project_rule"

    public enum Field: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        /// Exact sender address.
        case from
        /// Sender domain, e.g. "acme.com".
        case fromDomain
        /// Any recipient address or domain.
        case to
        case subjectContains
        /// Gmail label id or name.
        case label
        case account
        /// A search query in the app's search syntax.
        case query
    }

    public var id: Int64?
    public var projectId: String
    public var field: Field
    public var value: String

    public init(id: Int64? = nil, projectId: String, field: Field, value: String) {
        self.id = id
        self.projectId = projectId
        self.field = field
        self.value = value
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct ThreadProject: TernRecord, Hashable {
    public static let databaseTableName = "thread_project"

    public enum Source: String, Codable, Sendable, DatabaseValueConvertible { case rule, manual, ai }

    public var accountId: String
    public var threadId: String
    public var projectId: String
    public var source: Source

    public init(accountId: String, threadId: String, projectId: String, source: Source) {
        self.accountId = accountId
        self.threadId = threadId
        self.projectId = projectId
        self.source = source
    }
}

/// Snoozing is local: the thread leaves the inbox on Gmail and comes back at `until`.
public struct Snooze: TernRecord, Hashable {
    public static let databaseTableName = "snooze"

    public var accountId: String
    public var threadId: String
    public var until: Date

    public init(accountId: String, threadId: String, until: Date) {
        self.accountId = accountId
        self.threadId = threadId
        self.until = until
    }
}

// MARK: - Drafts, contacts, pending operations

/// Points at an attachment that still lives in Gmail, e.g. one carried over by a forward. The sender
/// fetches it (or uses the cached `MailAttachment.localPath`) before encoding the message.
public struct RemoteAttachmentRef: Codable, Hashable, Sendable {
    /// The account that owns the original message; may differ from the draft's account.
    public var accountId: String
    public var messageId: String
    public var partId: String
    /// Gmail attachment id. Nil when the data was inline in the message payload.
    public var attachmentId: String?

    public init(accountId: String, messageId: String, partId: String, attachmentId: String? = nil) {
        self.accountId = accountId
        self.messageId = messageId
        self.partId = partId
        self.attachmentId = attachmentId
    }
}

public struct DraftAttachment: Codable, Hashable, Sendable {
    /// Local file. Empty while `remote` has not been fetched yet.
    public var path: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Set for attachments that must be fetched from Gmail before sending (forwarded files).
    public var remote: RemoteAttachmentRef?
    /// Content-ID without angle brackets for inline images the body references as `cid:`.
    public var contentId: String?

    public init(
        path: String, filename: String, mimeType: String, size: Int,
        remote: RemoteAttachmentRef? = nil, contentId: String? = nil
    ) {
        self.path = path
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.remote = remote
        self.contentId = contentId
    }

    /// True when the file has to be downloaded from Gmail first.
    public var needsFetch: Bool { path.isEmpty && remote != nil }
}

public struct Draft: TernRecord, Hashable, Identifiable {
    public static let databaseTableName = "draft"

    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible { case new, reply, replyAll, forward }
    public enum State: String, Codable, Sendable, DatabaseValueConvertible {
        case editing, queued, sending, sent, failed
    }

    public var id: String
    public var accountId: String
    public var gmailDraftId: String?
    public var gmailMessageId: String?
    /// The thread being replied to or forwarded.
    public var threadId: String?
    /// The Gmail message being replied to or forwarded.
    public var replyToMessageId: String?
    public var kind: Kind
    public var toList: [Participant]
    public var ccList: [Participant]
    public var bccList: [Participant]
    public var subject: String
    public var bodyHtml: String
    public var attachments: [DraftAttachment]
    /// Send later. Nil sends as soon as the undo window passes.
    public var scheduledAt: Date?
    public var state: State
    public var lastError: String?
    public var updatedAt: Date
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString, accountId: String, gmailDraftId: String? = nil,
        gmailMessageId: String? = nil, threadId: String? = nil, replyToMessageId: String? = nil,
        kind: Kind = .new, toList: [Participant] = [], ccList: [Participant] = [],
        bccList: [Participant] = [], subject: String = "", bodyHtml: String = "",
        attachments: [DraftAttachment] = [], scheduledAt: Date? = nil, state: State = .editing,
        lastError: String? = nil, updatedAt: Date = Date(), createdAt: Date = Date()
    ) {
        self.id = id
        self.accountId = accountId
        self.gmailDraftId = gmailDraftId
        self.gmailMessageId = gmailMessageId
        self.threadId = threadId
        self.replyToMessageId = replyToMessageId
        self.kind = kind
        self.toList = toList
        self.ccList = ccList
        self.bccList = bccList
        self.subject = subject
        self.bodyHtml = bodyHtml
        self.attachments = attachments
        self.scheduledAt = scheduledAt
        self.state = state
        self.lastError = lastError
        self.updatedAt = updatedAt
        self.createdAt = createdAt
    }
}

/// Address book built from mail history, for recipient autocomplete.
public struct Contact: TernRecord, Hashable, Identifiable {
    public static let databaseTableName = "contact"

    /// Lowercased email.
    public var id: String
    public var name: String
    public var sentCount: Int
    public var receivedCount: Int
    public var lastContacted: Date?

    public init(id: String, name: String = "", sentCount: Int = 0, receivedCount: Int = 0, lastContacted: Date? = nil) {
        self.id = id
        self.name = name
        self.sentCount = sentCount
        self.receivedCount = receivedCount
        self.lastContacted = lastContacted
    }
}

/// Label edits for one message, computed at the moment the user acted.
public struct LabelChange: Codable, Hashable, Sendable {
    public var messageId: String
    public var add: [String]
    public var remove: [String]

    public init(messageId: String, add: [String], remove: [String]) {
        self.messageId = messageId
        self.add = add
        self.remove = remove
    }
}

/// A user action already applied locally, waiting to reach Gmail. Written by `MailStore`,
/// drained by the sync engine in id order per account.
public struct PendingOp: TernRecord, Hashable, Identifiable {
    public static let databaseTableName = "pending_op"

    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        /// Payload: `LabelOpPayload`.
        case modifyLabels
        /// Payload: `DraftOpPayload`. Send the draft once `notBefore` has passed.
        case sendDraft
        /// Payload: `DraftOpPayload`. Create or update the Gmail draft.
        case saveDraft
        /// Payload: `DraftOpPayload`.
        case deleteDraft
    }

    public enum State: String, Codable, Sendable, DatabaseValueConvertible { case pending, inflight, failed }

    public var id: Int64?
    public var accountId: String
    public var kind: Kind
    /// JSON payload; shape depends on `kind`.
    public var payload: String
    public var createdAt: Date
    /// Not before this moment (undo-send window, send later).
    public var notBefore: Date?
    public var attempts: Int
    public var lastError: String?
    public var state: State
    /// Set when the sync engine claims the op to send it: from then on a request for it may have
    /// reached Gmail (even if it's pending again after a failure), so undo can't simply drop it.
    public var dispatched: Bool

    public init(
        id: Int64? = nil, accountId: String, kind: Kind, payload: String, createdAt: Date = Date(),
        notBefore: Date? = nil, attempts: Int = 0, lastError: String? = nil, state: State = .pending,
        dispatched: Bool = false
    ) {
        self.id = id
        self.accountId = accountId
        self.kind = kind
        self.payload = payload
        self.createdAt = createdAt
        self.notBefore = notBefore
        self.attempts = attempts
        self.lastError = lastError
        self.state = state
        self.dispatched = dispatched
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

public struct LabelOpPayload: Codable, Hashable, Sendable {
    /// What the user did, for logs and for choosing a Gmail endpoint (e.g. threads.trash).
    public var action: String
    public var threadIds: [String]
    public var changes: [LabelChange]

    public init(action: String, threadIds: [String], changes: [LabelChange]) {
        self.action = action
        self.threadIds = threadIds
        self.changes = changes
    }
}

public struct DraftOpPayload: Codable, Hashable, Sendable {
    public var draftId: String
    /// Set on `deleteDraft`: the Gmail draft to delete. The local row is already gone (discard) or
    /// belongs to another account now when the op runs.
    public var gmailDraftId: String?
    /// Set on `sendDraft` by the sync engine once the Gmail draft it sends exists. From then on the
    /// send may already have gone out, so it can no longer be undone or discarded.
    public var sendingDraftId: String?
    /// Set on `sendDraft` by the sync engine when drafts.send answered that the staged draft is gone
    /// but Sent didn't show the message: how many times Sent has been checked again since. The send
    /// is never tried again from then on.
    public var confirmChecks: Int?

    public init(draftId: String, gmailDraftId: String? = nil, sendingDraftId: String? = nil, confirmChecks: Int? = nil) {
        self.draftId = draftId
        self.gmailDraftId = gmailDraftId
        self.sendingDraftId = sendingDraftId
        self.confirmChecks = confirmChecks
    }
}

// MARK: - Settings

public struct Setting: TernRecord, Hashable {
    public static let databaseTableName = "setting"

    public var key: String
    public var value: String

    public init(key: String, value: String) {
        self.key = key
        self.value = value
    }
}
