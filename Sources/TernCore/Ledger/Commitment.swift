import Foundation
import GRDB

/// Who owes the next action.
public enum LedgerDirection: String, Codable, Sendable, DatabaseValueConvertible { case waitingOn, iOwe }
/// Done and dismissed decisions stay sticky; reopened requests can resolve on later replies.
public enum CommitmentState: String, Codable, Sendable, DatabaseValueConvertible { case open, done, dismissed, stale }

/// A local promise or unanswered request, with evidence and room for later semantic resolution.
public struct Commitment: TernRecord, Hashable {
    public static let databaseTableName = "commitment"
    public var id: Int64?
    public var accountId: String
    public var threadId: String
    public var direction: LedgerDirection
    public var kind: String
    public var counterpartyEmail: String
    public var counterpartyName: String
    public var deliverable: String
    public var dueAt: Date?
    public var dueText: String?
    public var sourceMessageId: String
    public var sourceQuote: String
    public var sourceDate: Date
    public var origin: String
    public var confidence: Int
    public var state: CommitmentState
    public var stateSource: String
    public var resolvedMessageId: String?
    public var resolvedAt: Date?
    public var resolutionNote: String?
    public var hintMessageId: String?
    public var hintAt: Date?
    public var checkedCount: Int
    public var surfaceAt: Date
    public var surfaced: Bool
    public var fingerprint: String
    public var createdAt: Date
    public var updatedAt: Date
}

extension Commitment {
    /// Completion text shared by the reader and completed search rows.
    public var completionText: String {
        stateSource == "user" ? "Marked done by you" : "Closed automatically" + (resolutionNote.map { " · " + $0 } ?? "")
    }
}

/// Records the evidence version a later AI scan has inspected.
public struct LedgerScan: TernRecord, Hashable {
    public static let databaseTableName = "ledger_scan"
    public var accountId: String
    public var threadId: String
    public var messageCount: Int
    public var scannedAt: Date
    public var origin: String
    public var promptVersion: Int
}

/// The highest ranked commitment in a thread and the number behind it.
public struct CommitmentBrief: Hashable, Sendable {
    public var id: Int64
    public var direction: LedgerDirection = .waitingOn
    public var counterpartyEmail: String
    public var counterpartyName: String
    public var sourceDate: Date
    public var extraCount: Int
    public var surfaceAt: Date
    public var deliverable: String? = nil
    public var dueAt: Date? = nil
    public var hasHint: Bool = false
    public var isMaybe: Bool = false
    public var completion: String? = nil

    public func timeText(now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let dueAt else { return ageText(now: now) }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: dueAt)).day ?? 0
        switch days {
        case 0: return "Today"
        case 1: return "Tomorrow"
        case -1: return "Yesterday"
        case -14 ... -2: return "\(-days)d late"
        default:
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
            formatter.dateFormat = (2...6).contains(days) ? "EEE" : "MMM d"
            return formatter.string(from: dueAt)
        }
    }
    public func isOverdue(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        dueAt.map { calendar.startOfDay(for: $0) < calendar.startOfDay(for: now) } ?? false
    }
    /// Compact age for the list's single time slot.
    public func ageText(now: Date = Date()) -> String {
        "\(max(0, Int(now.timeIntervalSince(sourceDate) / 86_400)))d"
    }
    public var displayDeliverable: String? { deliverable.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
    public var displayName: String { counterpartyName.isEmpty ? counterpartyEmail : counterpartyName }
}

/// Exact previous rows for a local undo. No Gmail operation is queued.
public struct LedgerUndo: Hashable, Sendable {
    public var previous: [Commitment]
    /// Rows inserted by manual tracking, removed by undo.
    public var created: [Int64] = []
}

/// Mail preferences shared by detection, list reads and the settings page.
public struct LedgerSettings: Hashable, Sendable {
    public var enabled = true
    public var waitingDays = 3
    public var ai = true
    public var showMaybe = false
    public var aiDailyCalls = 40
    public var backfillDays = 30

    private final class Cached: NSObject {
        let value: LedgerSettings
        init(_ value: LedgerSettings) { self.value = value }
    }
    private static let cache: NSCache<NSString, Cached> = {
        let cache = NSCache<NSString, Cached>(); cache.countLimit = 16; return cache
    }()

    /// Reads only the six ledger keys; caches decoded settings by their exact stored values.
    /// Reading the keys on every call preserves observation invalidation and transaction visibility.
    public static func load(_ db: Database) throws -> LedgerSettings {
        let statement = try db.cachedStatement(sql: "SELECT * FROM setting WHERE key IN ('ledger.enabled','ledger.waitingDays','ledger.ai','ledger.showMaybe','ledger.aiDailyCalls','ledger.backfillDays') ORDER BY key")
        let rows = try Setting.fetchAll(statement)
        let key = NSString(data: try JSONEncoder().encode(rows.map { [$0.key, $0.value] }), encoding: String.Encoding.utf8.rawValue)!
        if let cached = cache.object(forKey: key) { return cached.value }
        let value = load(rows.reduce(into: [String: String]()) { $0[$1.key] = $1.value })
        cache.setObject(Cached(value), forKey: key)
        return value
    }

    static func load(_ settings: [String: String]) -> LedgerSettings {
        var result = LedgerSettings()
        result.enabled = settings["ledger.enabled"] != "false"
        result.waitingDays = Int(settings["ledger.waitingDays"] ?? "3").flatMap { [2, 3, 5, 7].contains($0) ? $0 : nil } ?? 3
        result.ai = settings["ledger.ai"] != "false"
        result.showMaybe = settings["ledger.showMaybe"] == "true"
        result.aiDailyCalls = max(0, Int(settings["ledger.aiDailyCalls"] ?? "40") ?? 40)
        result.backfillDays = min(30, max(1, Int(settings["ledger.backfillDays"] ?? "30") ?? 30))
        return result
    }
}
