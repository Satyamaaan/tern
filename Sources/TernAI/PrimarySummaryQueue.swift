import Foundation
import GRDB
import TernCore

/// Low-priority, durable Primary summaries. The timer also resumes work after a daily cap or transient error.
public actor PrimarySummaryQueue {
    private let database: AppDatabase
    private let assistant: MailAssistant
    private let providers: AIProviders
    private let idle: @Sendable () async -> Bool
    private let now: @Sendable () -> Date
    private let dailyLimit: Int
    private var loop: Task<Void, Never>?
    private var running = false
    private var generation = 0
    private var call: Task<[String], Error>?
    private var retryAfter: [ThreadKey: Date] = [:]

    public init(database: AppDatabase, assistant: MailAssistant, providers: AIProviders,
                dailyLimit: Int = 200, now: @escaping @Sendable () -> Date = { Date() },
                idle: @escaping @Sendable () async -> Bool = { true }) {
        self.database = database; self.assistant = assistant; self.providers = providers
        self.dailyLimit = dailyLimit; self.now = now; self.idle = idle
    }

    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    if try await self?.processNext() == true { continue }
                } catch { }
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
            }
        }
    }

    public func stop() { loop?.cancel(); loop = nil; call?.cancel() }
    public func yieldToForeground() { generation += 1; call?.cancel() }

    /// Selection is metadata-only, newest first, with all current Primary inbox mail included.
    public static func candidates(_ db: Database, now: Date, limit: Int = 1, tabs: [InboxTab] = [.primary]) throws -> [ThreadKey] {
        guard !tabs.isEmpty else { return [] }
        let conditions = tabs.map { $0.condition(gmailTab: "t.gmailTab", category: "ai.category") }
        var arguments = StatementArguments()
        for condition in conditions { arguments += condition.arguments }
        arguments += [now.addingTimeInterval(-30 * 86_400).timeIntervalSince1970, limit]
        return try Row.fetchAll(db, sql: """
            SELECT t.accountId,t.id FROM thread t
            LEFT JOIN thread_ai ai ON ai.accountId=t.accountId AND ai.threadId=t.id
            LEFT JOIN thread_summary sm ON sm.accountId=t.accountId AND sm.threadId=t.id
            WHERE (\(conditions.map(\.sql).joined(separator: " OR ")))
              AND (ai.category IS NULL OR ai.category NOT IN ('promotion','newsletter'))
              AND (t.lastDate>=? OR EXISTS(SELECT 1 FROM thread_label l
                WHERE l.accountId=t.accountId AND l.threadId=t.id AND l.labelId='INBOX'))
              AND (sm.threadId IS NULL OR sm.messageCount!=t.messageCount OR sm.lastDate!=t.lastDate)
              AND (ai.summary IS NULL OR ai.summary='' OR ai.messageCount!=t.messageCount)
              AND NOT EXISTS(SELECT 1 FROM message m WHERE m.accountId=t.accountId AND m.threadId=t.id AND m.listUnsubscribe IS NOT NULL)
              AND NOT EXISTS(SELECT 1 FROM thread_label x WHERE x.accountId=t.accountId AND x.threadId=t.id
                AND (x.labelId IN ('TRASH','SPAM','DRAFT','TERN_PENDING_MUTED') OR
                  x.labelId=(SELECT value FROM setting WHERE key='mute.label.' || t.accountId)))
            ORDER BY t.lastDate DESC,t.id,t.accountId LIMIT ?
            """, arguments: arguments)
            .map { ThreadKey(accountId: $0[0], threadId: $0[1]) }
    }

    /// One call at a time; foreground summaries and triage take precedence between calls.
    @discardableResult public func processNext() async throws -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false; call = nil }
        let generation = generation
        guard await idle(), !(await assistant.isBusy) else { return false }
        let settings = try await database.reader.read { try AISettings.read($0) }
        guard await providers.isEnabled(settings) else { return false }
        let stamp = now()
        let day = LedgerQueue.day(stamp)
        let retryAfter = retryAfter
        let limit = dailyLimit
        let key = try await database.writer.write { db -> ThreadKey? in
            guard try Setting.fetchOne(db, key: "ai.autoPrimarySummaries")?.value != "false" else { return nil }
            let saved = try Setting.fetchOne(db, key: "ai.summary.day")?.value.split(separator: ":") ?? []
            let count = saved.first.map(String.init) == day ? Int(saved.last ?? "0") ?? 0 : 0
            guard count < limit, let key = try Self.candidates(db, now: stamp, limit: 50).first(where: { retryAfter[$0].map { $0 > stamp } != true }) else { return nil }
            try Setting(key: "ai.summary.day", value: "\(day):\(count + 1)").upsert(db)
            return key
        }
        guard let key else { return false }
        let assistant = assistant
        let task = Task { try await assistant.summarize(thread: key, background: true) }
        call = task
        if generation != self.generation || Task.isCancelled { task.cancel() }
        do {
            _ = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            self.retryAfter[key] = nil
        } catch {
            let cancelled = error is CancellationError || task.isCancelled
            if cancelled {
                try await database.writer.write { db in
                    guard let value = try Setting.fetchOne(db, key: "ai.summary.day")?.value, value.hasPrefix(day + ":") else { return }
                    let count = Int(value.split(separator: ":").last ?? "0") ?? 0
                    try Setting(key: "ai.summary.day", value: "\(day):\(max(0, count - 1))").upsert(db)
                }
            } else { self.retryAfter[key] = stamp.addingTimeInterval(300) }
            if cancelled { throw CancellationError() }
            throw error
        }
        try await Task.sleep(for: .seconds(1))
        return true
    }
}
