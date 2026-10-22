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
    public var counterpartyEmail: String
    public var counterpartyName: String
    public var sourceDate: Date
    public var extraCount: Int
    public var surfaceAt: Date
    public var deliverable: String? = nil
    public var dueAt: Date? = nil
    public var hasHint: Bool = false

    public func timeText(now: Date = Date()) -> String {
        guard let dueAt else { return ageText(now: now) }
        let calendar = Calendar.current
        if calendar.isDate(dueAt, inSameDayAs: now) { return "Today" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = abs(dueAt.timeIntervalSince(now)) < 7 * 86_400 ? "EEE" : "MMM d"
        return formatter.string(from: dueAt)
    }
    public func isOverdue(now: Date = Date()) -> Bool {
        dueAt.map { $0 < Calendar.current.startOfDay(for: now) } ?? false
    }
    /// Compact age for the list's single time slot.
    public func ageText(now: Date = Date()) -> String {
        "\(max(0, Int(now.timeIntervalSince(sourceDate) / 86_400)))d"
    }
    public var displayName: String { counterpartyName.isEmpty ? counterpartyEmail : counterpartyName }
}

/// Exact previous rows for a local undo. No Gmail operation is queued.
public struct LedgerUndo: Hashable, Sendable {
    public var previous: [Commitment]
}

/// Mail preferences shared by detection, list reads and the settings page.
public struct LedgerSettings: Hashable, Sendable {
    public var enabled = true
    public var waitingDays = 3
    public var ai = true
    public var showMaybe = false
    public var aiDailyCalls = 40
    public var backfillDays = 14

    /// Reads defaults and validated values from the shared setting table.
    public static func load(_ db: Database) throws -> LedgerSettings {
        load(try Setting.fetchAll(db).reduce(into: [String: String]()) { $0[$1.key] = $1.value })
    }

    static func load(_ settings: [String: String]) -> LedgerSettings {
        var result = LedgerSettings()
        result.enabled = settings["ledger.enabled"] != "false"
        result.waitingDays = Int(settings["ledger.waitingDays"] ?? "3").flatMap { [2, 3, 5, 7].contains($0) ? $0 : nil } ?? 3
        result.ai = settings["ledger.ai"] != "false"
        result.showMaybe = settings["ledger.showMaybe"] == "true"
        result.aiDailyCalls = max(0, Int(settings["ledger.aiDailyCalls"] ?? "40") ?? 40)
        result.backfillDays = min(30, max(1, Int(settings["ledger.backfillDays"] ?? "14") ?? 14))
        return result
    }
}
