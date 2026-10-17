import Foundation
import GRDB

/// Something the user does to threads. Applied locally at once, then queued for Gmail.
public enum MailAction: Codable, Hashable, Sendable {
    case archive, moveToInbox, trash, untrash, markRead, markUnread, star, unstar, markSpam, notSpam
    case addLabel(String)
    case removeLabel(String)
    /// Archive and add a label, like Gmail's "Move to".
    case moveToLabel(String)
    case snooze(until: Date)
    case unsnooze

    public var name: String {
        switch self {
        case .archive: "archive"
        case .moveToInbox: "moveToInbox"
        case .trash: "trash"
        case .untrash: "untrash"
        case .markRead: "markRead"
        case .markUnread: "markUnread"
        case .star: "star"
        case .unstar: "unstar"
        case .markSpam: "markSpam"
        case .notSpam: "notSpam"
        case .addLabel: "addLabel"
        case .removeLabel: "removeLabel"
        case .moveToLabel: "moveToLabel"
        case .snooze: "snooze"
        case .unsnooze: "unsnooze"
        }
    }

    /// True when the thread leaves the current list (the UI then selects the next one).
    public var removesFromInbox: Bool {
        switch self {
        case .archive, .trash, .markSpam, .moveToLabel, .snooze: true
        default: false
        }
    }
}

/// Everything needed to put threads back the way they were.
public struct UndoToken: Sendable, Hashable {
    public let action: MailAction
    public let threads: [ThreadKey]
    let opIds: [Int64]
    let previousLabels: [MessageKey: [String]]
    let previousSnoozes: [ThreadKey: Date?]
}

extension MailStore {
    /// Applies the action to the local database and queues it for Gmail, in one transaction.
    @discardableResult
    public func perform(_ action: MailAction, on threads: [ThreadKey]) throws -> UndoToken {
        try database.writer.write { db in try Self.perform(db, action, on: threads) }
    }

    public static func perform(_ db: Database, _ action: MailAction, on threads: [ThreadKey]) throws -> UndoToken {
        var previousLabels: [MessageKey: [String]] = [:]
        var previousSnoozes: [ThreadKey: Date?] = [:]
        var opIds: [Int64] = []

        for (accountId, keys) in Dictionary(grouping: threads, by: \.accountId) {
            let threadIds = keys.map(\.threadId)
            let messages = try messageLabels(db, accountId: accountId, threadIds: threadIds)
            var changes: [LabelChange] = []
            var newLabels: [String: [String]] = [:]

            for (threadId, threadMessages) in Dictionary(grouping: messages, by: \.threadId) {
                for change in labelChanges(for: action, messages: threadMessages) {
                    guard let message = threadMessages.first(where: { $0.id == change.messageId }) else { continue }
                    var labels = Set(message.labelIds)
                    labels.subtract(change.remove)
                    labels.formUnion(change.add)
                    let effective = LabelChange(
                        messageId: change.messageId,
                        add: change.add.filter { !message.labelIds.contains($0) },
                        remove: change.remove.filter { message.labelIds.contains($0) })
                    guard !effective.add.isEmpty || !effective.remove.isEmpty else { continue }
                    previousLabels[MessageKey(accountId: accountId, messageId: message.id)] = message.labelIds
                    newLabels[message.id] = labels.sorted()
                    changes.append(effective)
                }
                let key = ThreadKey(accountId: accountId, threadId: threadId)
                switch action {
                case .snooze(let until):
                    previousSnoozes[key] = try Snooze.fetchOne(db, key: ["accountId": accountId, "threadId": threadId])?.until
                    try Snooze(accountId: accountId, threadId: threadId, until: until).upsert(db)
                case .unsnooze:
                    previousSnoozes[key] = try Snooze.fetchOne(db, key: ["accountId": accountId, "threadId": threadId])?.until
                    _ = try Snooze.deleteOne(db, key: ["accountId": accountId, "threadId": threadId])
                default:
                    break
                }
            }

            try setLabels(db, accountId: accountId, newLabels)
            if !changes.isEmpty {
                let payload = LabelOpPayload(action: action.name, threadIds: threadIds, changes: changes)
                let op = PendingOp(accountId: accountId, kind: .modifyLabels, payload: try encodeJSON(payload))
                try op.insert(db)
                opIds.append(db.lastInsertedRowID)
            }
        }

        return UndoToken(
            action: action, threads: threads, opIds: opIds, previousLabels: previousLabels,
            previousSnoozes: previousSnoozes)
    }

    /// Applies a different action to each group of threads (e.g. a label whose id differs per account)
    /// in one transaction, with one undo for all of it, named after the first action.
    @discardableResult
    public func perform(_ actions: [(action: MailAction, threads: [ThreadKey])]) throws -> UndoToken {
        try database.writer.write { db in try Self.perform(db, actions) }
    }

    public static func perform(_ db: Database, _ actions: [(action: MailAction, threads: [ThreadKey])]) throws -> UndoToken {
        guard let first = actions.first else { return try perform(db, .archive, on: []) }
        var threads: [ThreadKey] = []
        var opIds: [Int64] = []
        var previousLabels: [MessageKey: [String]] = [:]
        var previousSnoozes: [ThreadKey: Date?] = [:]
        for item in actions {
            let token = try perform(db, item.action, on: item.threads)
            threads += token.threads
            opIds += token.opIds
            previousLabels.merge(token.previousLabels) { earlier, _ in earlier }
            previousSnoozes.merge(token.previousSnoozes) { earlier, _ in earlier }
        }
        return UndoToken(action: first.action, threads: threads, opIds: opIds, previousLabels: previousLabels,
                         previousSnoozes: previousSnoozes)
    }

    /// Puts threads back. If Gmail hasn't seen the action yet, the queued op is simply dropped.
    public func undo(_ token: UndoToken) throws {
        try database.writer.write { db in
            let stillQueued = try PendingOp
                .filter(token.opIds.contains(Column("id")) && Column("state") == PendingOp.State.pending.rawValue)
                .fetchAll(db)
            let canDrop = stillQueued.count == token.opIds.count
            if canDrop {
                _ = try PendingOp.deleteAll(db, keys: token.opIds)
            }

            for (accountId, entries) in Dictionary(grouping: token.previousLabels, by: \.key.accountId) {
                var restore: [String: [String]] = [:]
                var changes: [LabelChange] = []
                let current = try Self.messageLabels(db, accountId: accountId, messageIds: entries.map(\.key.messageId))
                for (key, previous) in entries {
                    restore[key.messageId] = previous
                    let now = current[key.messageId] ?? []
                    let change = LabelChange(
                        messageId: key.messageId,
                        add: previous.filter { !now.contains($0) },
                        remove: now.filter { !previous.contains($0) })
                    if !change.add.isEmpty || !change.remove.isEmpty { changes.append(change) }
                }
                try Self.setLabels(db, accountId: accountId, restore)
                if !canDrop, !changes.isEmpty {
                    let threadIds = token.threads.filter { $0.accountId == accountId }.map(\.threadId)
                    let payload = LabelOpPayload(action: "undo-\(token.action.name)", threadIds: threadIds, changes: changes)
                    let op = PendingOp(accountId: accountId, kind: .modifyLabels, payload: try encodeJSON(payload))
                    try op.insert(db)
                }
            }

            for (key, until) in token.previousSnoozes {
                if let until {
                    try Snooze(accountId: key.accountId, threadId: key.threadId, until: until).upsert(db)
                } else {
                    _ = try Snooze.deleteOne(db, key: ["accountId": key.accountId, "threadId": key.threadId])
                }
            }
        }
    }

    /// Returns snoozed threads whose time has come to the inbox, unread. Returns their keys.
    @discardableResult
    public func wakeSnoozed(now: Date = Date()) throws -> [ThreadKey] {
        try database.writer.write { db in
            let due = try Snooze.filter(Column("until") <= now.timeIntervalSince1970).fetchAll(db)
            let keys = due.map { ThreadKey(accountId: $0.accountId, threadId: $0.threadId) }
            guard !keys.isEmpty else { return [] }
            _ = try Self.perform(db, .unsnooze, on: keys)
            _ = try Self.perform(db, .markUnread, on: keys)
            return keys
        }
    }

    /// Adds or removes threads from a project by hand. Local only.
    public func setProject(_ projectId: String, on threads: [ThreadKey], assigned: Bool) throws {
        try database.writer.write { db in
            for key in threads {
                if assigned {
                    try ThreadProject(accountId: key.accountId, threadId: key.threadId, projectId: projectId, source: .manual)
                        .upsert(db)
                } else {
                    _ = try ThreadProject.deleteOne(db, key: [
                        "accountId": key.accountId, "threadId": key.threadId, "projectId": projectId,
                    ])
                }
            }
        }
    }

    // MARK: Label rules

    struct MessageLabels: Decodable, FetchableRecord {
        var id: String
        var threadId: String
        var date: Double
        var labelIds: [String]
        var isDraft: Bool
        var isFromMe: Bool
    }

    static func messageLabels(_ db: Database, accountId: String, threadIds: [String]) throws -> [MessageLabels] {
        guard !threadIds.isEmpty else { return [] }
        let placeholders = databaseQuestionMarks(count: threadIds.count)
        return try MessageLabels.fetchAll(db, sql: """
            SELECT id, threadId, date, labelIds, isDraft, isFromMe FROM message
            WHERE accountId = ? AND threadId IN (\(placeholders)) ORDER BY date
            """, arguments: StatementArguments([accountId] + threadIds))
    }

    static func messageLabels(_ db: Database, accountId: String, messageIds: [String]) throws -> [String: [String]] {
        guard !messageIds.isEmpty else { return [:] }
        let placeholders = databaseQuestionMarks(count: messageIds.count)
        let rows = try Row.fetchAll(db, sql: """
            SELECT id, labelIds FROM message WHERE accountId = ? AND id IN (\(placeholders))
            """, arguments: StatementArguments([accountId] + messageIds))
        var result: [String: [String]] = [:]
        for row in rows {
            let json: String = row["labelIds"]
            result[row["id"]] = (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? []
        }
        return result
    }

    /// The per-message label edits that make up an action, following Gmail's own semantics.
    static func labelChanges(for action: MailAction, messages: [MessageLabels]) -> [LabelChange] {
        let real = messages.filter { !$0.isDraft }
        func all(add: [String] = [], remove: [String] = []) -> [LabelChange] {
            real.map { LabelChange(messageId: $0.id, add: add, remove: remove) }
        }
        switch action {
        case .archive, .snooze:
            return all(remove: [SystemLabel.inbox])
        case .moveToInbox:
            return all(add: [SystemLabel.inbox], remove: [SystemLabel.trash, SystemLabel.spam])
        case .trash:
            return all(add: [SystemLabel.trash], remove: [SystemLabel.inbox, SystemLabel.spam])
        case .untrash:
            return all(add: [SystemLabel.inbox], remove: [SystemLabel.trash])
        case .markRead:
            return all(remove: [SystemLabel.unread])
        case .markUnread:
            let target = real.last(where: { !$0.isFromMe }) ?? real.last
            return target.map { [LabelChange(messageId: $0.id, add: [SystemLabel.unread], remove: [])] } ?? []
        case .star:
            return real.last.map { [LabelChange(messageId: $0.id, add: [SystemLabel.starred], remove: [])] } ?? []
        case .unstar:
            return all(remove: [SystemLabel.starred])
        case .markSpam:
            return all(add: [SystemLabel.spam], remove: [SystemLabel.inbox])
        case .notSpam:
            return all(add: [SystemLabel.inbox], remove: [SystemLabel.spam])
        case .addLabel(let id):
            return all(add: [id])
        case .removeLabel(let id):
            return all(remove: [id])
        case .moveToLabel(let id):
            return all(add: [id], remove: [SystemLabel.inbox])
        case .unsnooze:
            return all(add: [SystemLabel.inbox])
        }
    }
}

func encodeJSON<T: Encodable>(_ value: T) throws -> String {
    String(data: try JSONEncoder().encode(value), encoding: .utf8)!
}
