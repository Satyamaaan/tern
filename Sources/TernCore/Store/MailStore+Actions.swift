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

    /// Adds or removes a user label, which project rules may look at.
    var changesUserLabels: Bool {
        switch self {
        case .addLabel, .removeLabel, .moveToLabel: true
        default: false
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
    /// The ops the action queued, oldest first.
    let ops: [QueuedChanges]
    let previousSnoozes: [ThreadKey: Date?]
}

/// One op an action queued: its exact per-message changes, and each changed message's labels right
/// after it, so undo can tell whether anything changed those messages since.
struct QueuedChanges: Sendable, Hashable {
    let opId: Int64
    let accountId: String
    let changes: [LabelChange]
    let labelsAfter: [String: [String]]
}

extension LabelChange {
    /// The change that takes this one back.
    var reversed: LabelChange { LabelChange(messageId: messageId, add: remove, remove: add) }
}

extension MailStore {
    /// Applies the action to the local database and queues it for Gmail, in one transaction.
    @discardableResult
    public func perform(_ action: MailAction, on threads: [ThreadKey]) throws -> UndoToken {
        try database.writer.write { db in try Self.perform(db, action, on: threads) }
    }

    public static func perform(_ db: Database, _ action: MailAction, on threads: [ThreadKey]) throws -> UndoToken {
        var previousSnoozes: [ThreadKey: Date?] = [:]
        var ops: [QueuedChanges] = []

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
                ops.append(QueuedChanges(opId: db.lastInsertedRowID, accountId: accountId, changes: changes, labelsAfter: newLabels))
            }
        }

        // Gmail echoes the change back unchanged, so sync won't re-run label-based project rules.
        if action.changesUserLabels { try ProjectRules.apply(db, keys: Set(threads)) }
        return UndoToken(action: action, threads: threads, ops: ops, previousSnoozes: previousSnoozes)
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
        var ops: [QueuedChanges] = []
        var previousSnoozes: [ThreadKey: Date?] = [:]
        for item in actions {
            let token = try perform(db, item.action, on: item.threads)
            threads += token.threads
            ops += token.ops
            previousSnoozes.merge(token.previousSnoozes) { earlier, _ in earlier }
        }
        return UndoToken(action: first.action, threads: threads, ops: ops, previousSnoozes: previousSnoozes)
    }

    /// Puts threads back by taking each message's exact change back from its current labels, so changes
    /// made since (another action, sync) survive. A queued op is dropped only when Gmail can't have
    /// seen it (it was never dispatched) and nothing has changed its messages since; otherwise the
    /// exact reverse goes to Gmail after it, as one op per account.
    public func undo(_ token: UndoToken) throws {
        try database.writer.write { db in
            var reverse: [String: [LabelChange]] = [:]
            // Newest first, so each op is checked against the labels it left behind.
            for queued in token.ops.reversed() {
                let current = try Self.messageLabels(db, accountId: queued.accountId, messageIds: Array(queued.labelsAfter.keys))
                let muted = try Setting.fetchOne(db, key: Self.muteLabelKey(queued.accountId))?.value
                let changes = queued.changes.map { Self.resolvingPendingMute($0, muted: muted, labels: current[$0.messageId]) }
                let untouched = queued.labelsAfter.allSatisfy { id, after in current[id].map(Set.init) == Set(after) }
                if untouched, let op = try PendingOp.fetchOne(db, key: queued.opId), op.state == .pending, !op.dispatched {
                    try op.delete(db)
                } else {
                    reverse[queued.accountId, default: []] += changes.map(\.reversed)
                }
                var restore: [String: [String]] = [:]
                for change in changes {
                    guard var labels = current[change.messageId].map(Set.init) else { continue }
                    labels.subtract(change.add)
                    labels.formUnion(change.remove)
                    restore[change.messageId] = labels.sorted()
                }
                try Self.setLabels(db, accountId: queued.accountId, restore)
            }

            for (accountId, changes) in reverse {
                let net = Self.netChanges(changes)
                guard !net.isEmpty else { continue }
                let threadIds = token.threads.filter { $0.accountId == accountId }.map(\.threadId)
                let payload = LabelOpPayload(action: "undo-\(token.action.name)", threadIds: threadIds, changes: net)
                try PendingOp(accountId: accountId, kind: .modifyLabels, payload: try encodeJSON(payload)).insert(db)
            }

            if token.action.changesUserLabels { try ProjectRules.apply(db, keys: Set(token.threads)) }

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
            if assigned {
                try ProjectRules.assignByHand(db, threads, to: projectId)
            } else {
                try ProjectRules.removeByHand(db, threads, from: projectId)
            }
        }
    }

    /// One change per message with the combined effect of `changes` applied in order.
    static func netChanges(_ changes: [LabelChange]) -> [LabelChange] {
        var order: [String] = []
        var add: [String: Set<String>] = [:]
        var remove: [String: Set<String>] = [:]
        for change in changes {
            if add[change.messageId] == nil {
                order.append(change.messageId)
                add[change.messageId] = []
                remove[change.messageId] = []
            }
            for label in change.remove {
                add[change.messageId]?.remove(label)
                remove[change.messageId]?.insert(label)
            }
            for label in change.add {
                remove[change.messageId]?.remove(label)
                add[change.messageId]?.insert(label)
            }
        }
        return order.compactMap { id in
            let change = LabelChange(messageId: id, add: (add[id] ?? []).sorted(), remove: (remove[id] ?? []).sorted())
            return change.add.isEmpty && change.remove.isEmpty ? nil : change
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
