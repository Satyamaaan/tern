import Foundation

// The contract between the Google client (Sources/TernSync/Google) and the sync engine
// (Sources/TernSync/Engine). The engine and its tests use an in-memory fake; the app uses the
// real HTTP client. Types mirror Gmail API v1 JSON so they decode directly.

/// One signed-in Gmail account's API.
public protocol GmailAPI: Sendable {
    func profile() async throws -> GmailProfile

    func labels() async throws -> [GmailLabel]
    func createLabel(name: String) async throws -> GmailLabel
    func deleteLabel(id: String) async throws

    /// users.messages.list. `query` uses Gmail search syntax.
    func messageIds(query: String?, labelIds: [String], pageToken: String?, maxResults: Int) async throws -> GmailIdPage
    /// users.messages.get for many ids, batched internally. Ids that no longer exist are omitted.
    func messages(ids: [String], format: GmailMessageFormat) async throws -> [GmailMessage]
    /// users.threads.get for many ids, batched internally. Ids that no longer exist are omitted.
    /// One full-format thread costs 120 quota units, two full messages.get calls cost the same,
    /// so the engine prefers it for threads of three or more messages.
    func threads(ids: [String], format: GmailMessageFormat) async throws -> [GmailThread]
    /// users.history.list. Throws `GmailAPIError.historyExpired` when `startHistoryId` is too old.
    func history(startHistoryId: String, pageToken: String?) async throws -> GmailHistoryPage

    func batchModify(messageIds: [String], add: [String], remove: [String]) async throws
    func trashThread(id: String) async throws
    func untrashThread(id: String) async throws

    func attachment(messageId: String, attachmentId: String) async throws -> Data

    /// Sends an RFC 822 message. Pass `threadId` for replies so Gmail keeps the conversation.
    func send(raw: Data, threadId: String?) async throws -> GmailMessageRef
    func createDraft(raw: Data, threadId: String?) async throws -> GmailDraft
    func updateDraft(id: String, raw: Data, threadId: String?) async throws -> GmailDraft
    func deleteDraft(id: String) async throws
    func sendDraft(id: String) async throws -> GmailMessageRef

    /// Send-as identities with signatures.
    func sendAs() async throws -> [GmailSendAs]
}

extension GmailAPI {
    /// Default for clients without threads.get; the engine then falls back to messages.get.
    public func threads(ids: [String], format: GmailMessageFormat) async throws -> [GmailThread] {
        throw GmailAPIError.server(status: 501, message: GmailThread.unsupported)
    }
}

public enum GmailAPIError: Error, Sendable, Equatable {
    /// Token revoked or expired beyond refresh; the account needs to sign in again.
    case unauthorized
    case notFound
    /// history.list 404: the stored historyId is too old, a full resync is needed.
    case historyExpired
    case rateLimited(retryAfter: Double?)
    case server(status: Int, message: String)
    case network(String)
}

public enum GmailMessageFormat: String, Sendable {
    case minimal, metadata, full, raw
}

public struct GmailProfile: Codable, Sendable, Hashable {
    public var emailAddress: String
    public var messagesTotal: Int?
    public var threadsTotal: Int?
    public var historyId: String

    public init(emailAddress: String, messagesTotal: Int? = nil, threadsTotal: Int? = nil, historyId: String) {
        self.emailAddress = emailAddress
        self.messagesTotal = messagesTotal
        self.threadsTotal = threadsTotal
        self.historyId = historyId
    }
}

public struct GmailLabelColor: Codable, Sendable, Hashable {
    public var textColor: String?
    public var backgroundColor: String?

    public init(textColor: String? = nil, backgroundColor: String? = nil) {
        self.textColor = textColor
        self.backgroundColor = backgroundColor
    }
}

public struct GmailLabel: Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    /// "system" or "user".
    public var type: String?
    public var messageListVisibility: String?
    public var labelListVisibility: String?
    public var color: GmailLabelColor?

    public init(id: String, name: String, type: String? = nil, messageListVisibility: String? = nil,
                labelListVisibility: String? = nil, color: GmailLabelColor? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.messageListVisibility = messageListVisibility
        self.labelListVisibility = labelListVisibility
        self.color = color
    }
}

public struct GmailMessageRef: Codable, Sendable, Hashable {
    public var id: String
    public var threadId: String

    public init(id: String, threadId: String) {
        self.id = id
        self.threadId = threadId
    }
}

public struct GmailIdPage: Codable, Sendable, Hashable {
    public var messages: [GmailMessageRef]?
    public var nextPageToken: String?
    public var resultSizeEstimate: Int?

    public init(messages: [GmailMessageRef]? = nil, nextPageToken: String? = nil, resultSizeEstimate: Int? = nil) {
        self.messages = messages
        self.nextPageToken = nextPageToken
        self.resultSizeEstimate = resultSizeEstimate
    }
}

public struct GmailHeader: Codable, Sendable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct GmailPartBody: Codable, Sendable, Hashable {
    public var attachmentId: String?
    public var size: Int?
    /// base64url, already decoded from the transfer encoding but still in the part's charset.
    public var data: String?

    public init(attachmentId: String? = nil, size: Int? = nil, data: String? = nil) {
        self.attachmentId = attachmentId
        self.size = size
        self.data = data
    }
}

public struct GmailMessagePart: Codable, Sendable, Hashable {
    public var partId: String?
    public var mimeType: String?
    public var filename: String?
    public var headers: [GmailHeader]?
    public var body: GmailPartBody?
    public var parts: [GmailMessagePart]?

    public init(partId: String? = nil, mimeType: String? = nil, filename: String? = nil,
                headers: [GmailHeader]? = nil, body: GmailPartBody? = nil, parts: [GmailMessagePart]? = nil) {
        self.partId = partId
        self.mimeType = mimeType
        self.filename = filename
        self.headers = headers
        self.body = body
        self.parts = parts
    }

    public func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

public struct GmailMessage: Codable, Sendable, Hashable {
    public var id: String
    public var threadId: String
    public var labelIds: [String]?
    public var snippet: String?
    public var historyId: String?
    /// Milliseconds since 1970, as a string.
    public var internalDate: String?
    public var payload: GmailMessagePart?
    public var sizeEstimate: Int?
    /// base64url RFC 822, only with format=raw.
    public var raw: String?

    public init(id: String, threadId: String, labelIds: [String]? = nil, snippet: String? = nil,
                historyId: String? = nil, internalDate: String? = nil, payload: GmailMessagePart? = nil,
                sizeEstimate: Int? = nil, raw: String? = nil) {
        self.id = id
        self.threadId = threadId
        self.labelIds = labelIds
        self.snippet = snippet
        self.historyId = historyId
        self.internalDate = internalDate
        self.payload = payload
        self.sizeEstimate = sizeEstimate
        self.raw = raw
    }
}

public struct GmailThread: Codable, Sendable, Hashable {
    public var id: String
    public var snippet: String?
    public var historyId: String?
    /// Oldest first.
    public var messages: [GmailMessage]?

    public init(id: String, snippet: String? = nil, historyId: String? = nil, messages: [GmailMessage]? = nil) {
        self.id = id
        self.snippet = snippet
        self.historyId = historyId
        self.messages = messages
    }

    /// The message of the default `threads(ids:format:)`.
    public static let unsupported = "threads.get is not implemented by this client"
}

public struct GmailHistoryMessage: Codable, Sendable, Hashable {
    public var message: GmailMessage

    public init(message: GmailMessage) {
        self.message = message
    }
}

public struct GmailHistoryLabelChange: Codable, Sendable, Hashable {
    public var message: GmailMessage
    public var labelIds: [String]

    public init(message: GmailMessage, labelIds: [String]) {
        self.message = message
        self.labelIds = labelIds
    }
}

public struct GmailHistory: Codable, Sendable, Hashable {
    public var id: String
    public var messages: [GmailMessageRef]?
    public var messagesAdded: [GmailHistoryMessage]?
    public var messagesDeleted: [GmailHistoryMessage]?
    public var labelsAdded: [GmailHistoryLabelChange]?
    public var labelsRemoved: [GmailHistoryLabelChange]?

    public init(id: String, messages: [GmailMessageRef]? = nil, messagesAdded: [GmailHistoryMessage]? = nil,
                messagesDeleted: [GmailHistoryMessage]? = nil, labelsAdded: [GmailHistoryLabelChange]? = nil,
                labelsRemoved: [GmailHistoryLabelChange]? = nil) {
        self.id = id
        self.messages = messages
        self.messagesAdded = messagesAdded
        self.messagesDeleted = messagesDeleted
        self.labelsAdded = labelsAdded
        self.labelsRemoved = labelsRemoved
    }
}

public struct GmailHistoryPage: Codable, Sendable, Hashable {
    public var history: [GmailHistory]?
    public var nextPageToken: String?
    /// The mailbox's current historyId.
    public var historyId: String?

    public init(history: [GmailHistory]? = nil, nextPageToken: String? = nil, historyId: String? = nil) {
        self.history = history
        self.nextPageToken = nextPageToken
        self.historyId = historyId
    }
}

public struct GmailDraft: Codable, Sendable, Hashable {
    public var id: String
    public var message: GmailMessage?

    public init(id: String, message: GmailMessage? = nil) {
        self.id = id
        self.message = message
    }
}

public struct GmailSendAs: Codable, Sendable, Hashable {
    public var sendAsEmail: String
    public var displayName: String?
    public var replyToAddress: String?
    /// HTML signature.
    public var signature: String?
    public var isPrimary: Bool?
    public var isDefault: Bool?

    public init(sendAsEmail: String, displayName: String? = nil, replyToAddress: String? = nil,
                signature: String? = nil, isPrimary: Bool? = nil, isDefault: Bool? = nil) {
        self.sendAsEmail = sendAsEmail
        self.displayName = displayName
        self.replyToAddress = replyToAddress
        self.signature = signature
        self.isPrimary = isPrimary
        self.isDefault = isDefault
    }
}
