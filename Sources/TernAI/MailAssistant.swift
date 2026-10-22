import Foundation
import GRDB
import TernCore

/// On-demand AI features for one thread or one search, through the provider the settings select.
/// Every call throws `AIError.disabled` while `ai.enabled` is off.
public actor MailAssistant {
    public let database: AppDatabase
    public let providers: AIProviders
    private let now: @Sendable () -> Date

    private var userRequests = 0
    public var isBusy: Bool { userRequests > 0 }

    public init(database: AppDatabase, providers: AIProviders = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.database = database
        self.providers = providers
        self.now = now
    }

    /// Two to four bullets, saved locally until the conversation changes.
    public func summarize(thread key: ThreadKey, background: Bool = false) async throws -> [String] {
        try Task.checkCancellation()
        let settings = try await database.reader.read { try AISettings.read($0) }
        guard await providers.isEnabled(settings) else { throw AIError.disabled }
        if !background { userRequests += 1 }
        defer { if !background { userRequests -= 1 } }
        if let saved = try await database.reader.read({ db in
            try String.fetchOne(db, sql: """
                SELECT sm.bullets FROM thread_summary sm JOIN thread t ON t.accountId=sm.accountId AND t.id=sm.threadId
                WHERE sm.accountId=? AND sm.threadId=? AND sm.messageCount=t.messageCount AND sm.lastDate=t.lastDate
                """, arguments: [key.accountId, key.threadId])
        }), let bullets = try? JSONDecoder().decode([String].self, from: Data(saved.utf8)) { return bullets }

        let thread = try await load(key, messages: 12, characters: 1_200)
        var request = Prompts.summary(thread)
        request.isBackground = background
        let object = try await ask(request)
        let bullets = (object["bullets"] as? [Any] ?? []).compactMap(Loose.string)
            .map { MailText.compact($0.trimmingCharacters(in: CharacterSet(charactersIn: " -•*")), limit: 140) }
            .filter { !$0.isEmpty }
            .prefix(4)
        guard !bullets.isEmpty else { throw AIError.invalidOutput("The summary was empty.") }
        try Task.checkCancellation()
        try await database.writer.write { db in
            guard try AISettings.read(db) == settings else { throw CancellationError() }
            if background, try Setting.fetchOne(db, key: "ai.autoPrimarySummaries")?.value == "false" { throw CancellationError() }
            try SummaryStore.save(db, key: key, messageCount: thread.messageCount, lastDate: thread.lastDate, bullets: Array(bullets))
        }
        return Array(bullets)
    }

    /// Three short reply options (at most 12 words each) for the latest message.
    public func suggestReplies(thread key: ThreadKey) async throws -> [String] {
        let thread = try await load(key, messages: 6, characters: 800)
        let samples = try await database.reader.read { db in try PromptData.ownSamples(db, thread: thread, limit: 3, characters: 300) }
        let object = try await ask(Prompts.replies(thread, samples: samples))
        let replies = (object["replies"] as? [Any] ?? []).compactMap(Loose.string)
            .map { Self.words($0, limit: 12) }
            .filter { !$0.isEmpty }
        guard !replies.isEmpty else { throw AIError.invalidOutput("No reply suggestions came back.") }
        return Array(replies.prefix(3))
    }

    /// A reply body as composer HTML, in the user's voice (few-shot from their own sent mail), following
    /// `instruction` (e.g. "say yes, propose Thursday").
    public func draftReply(thread key: ThreadKey, instruction: String) async throws -> String {
        let thread = try await load(key, messages: 6, characters: 1_500)
        let (samples, ownerName) = try await database.reader.read { db in
            let samples = try PromptData.ownSamples(db, thread: thread, limit: 3, characters: 600)
            let name = try String.fetchOne(db, sql: """
                SELECT fromName FROM message WHERE accountId = ? AND isFromMe = 1 AND fromName != ''
                ORDER BY date DESC LIMIT 1
                """, arguments: [key.accountId]) ?? ""
            return (samples, name)
        }
        let object = try await ask(Prompts.draft(thread, samples: samples, instruction: instruction, ownerName: ownerName))
        guard let body = Loose.string(object["body"])?.trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty else {
            throw AIError.invalidOutput("The draft was empty.")
        }
        return Self.html(fromPlainText: body)
    }

    /// Tern search syntax for a plain-language request, e.g. "pdfs from maya last month" →
    /// `from:maya has:attachment filename:pdf newer_than:1m`.
    public func naturalLanguageToQuery(_ text: String) async throws -> String {
        let (accounts, labels, projects) = try await database.reader.read { db in
            (
                try String.fetchAll(db, sql: "SELECT email FROM account ORDER BY sortOrder, email"),
                try String.fetchAll(db, sql: "SELECT DISTINCT name FROM label WHERE type = 'user' AND hidden = 0 ORDER BY name LIMIT 100"),
                try String.fetchAll(db, sql: "SELECT name FROM project ORDER BY sortOrder, name")
            )
        }
        let object = try await ask(Prompts.searchQuery(text, today: now(), accounts: accounts, labels: labels, projects: projects))
        let query = Loose.string(object["query"]).map { MailText.compact($0, limit: 300) } ?? ""
        guard !query.isEmpty else { throw AIError.invalidOutput("No query came back.") }
        return query
    }

    // MARK: Helpers

    private func load(_ key: ThreadKey, messages: Int, characters: Int) async throws -> PromptThread {
        let thread = try await database.reader.read { db in
            try PromptData.threads(db, keys: [key], messages: messages, characters: characters).first
        }
        guard let thread else { throw AIError.failed("That conversation is no longer in the mailbox.") }
        return thread
    }

    /// Runs the request with the selected provider; reads the answer as a JSON object, retrying once.
    private func ask(_ request: AIRequest) async throws -> [String: Any] {
        let settings = try await database.reader.read { db in try AISettings.read(db) }
        let provider = try await providers.resolve(settings)
        var request = request
        request.model = settings.model(for: provider)
        for _ in 1...2 {
            try Task.checkCancellation()
            let answer = try await provider.complete(request)
            if let object = ModelJSON.parse(answer) as? [String: Any] { return object }
        }
        throw AIError.invalidOutput("The answer couldn't be read.")
    }

    static func words(_ text: String, limit: Int) -> String {
        let cleaned = text.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\"'“”-•*"))
        let words = cleaned.split(whereSeparator: \.isWhitespace)
        return words.prefix(limit).joined(separator: " ")
    }

    /// Paragraphs and line breaks as Gmail-style composer HTML, with the text escaped.
    static func html(fromPlainText text: String) -> String {
        let escaped = { (line: Substring) in
            line.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
        let body = lines.map { $0.trimmingCharacters(in: .whitespaces).isEmpty ? "<div><br></div>" : "<div>\(escaped($0))</div>" }
        return "<div dir=\"ltr\">\(body.joined())</div>"
    }
}
