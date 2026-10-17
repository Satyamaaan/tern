import Foundation
import GRDB
@testable import TernAI
import TernCore

/// Records every launch and answers from a script; never spawns anything.
final class FakeRunner: ProcessRunner, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(invocation: ProcessInvocation, timeout: TimeInterval)] = []
    private let handler: @Sendable (ProcessInvocation) async throws -> ProcessResult

    init(_ handler: @escaping @Sendable (ProcessInvocation) async throws -> ProcessResult) {
        self.handler = handler
    }

    var invocations: [ProcessInvocation] { lock.withLock { recorded.map(\.invocation) } }
    var timeouts: [TimeInterval] { lock.withLock { recorded.map(\.timeout) } }

    func run(_ invocation: ProcessInvocation, timeout: TimeInterval) async throws -> ProcessResult {
        lock.withLock { recorded.append((invocation, timeout)) }
        return try await handler(invocation)
    }
}

/// A provider that answers from a closure and keeps every request.
final class FakeProvider: AIProvider, @unchecked Sendable {
    let id: String
    let displayName: String
    private let lock = NSLock()
    private var log: [AIRequest] = []
    private var state: AIAvailability
    private let responder: @Sendable (AIRequest, Int) async throws -> String

    init(id: String = "codex", availability: AIAvailability = .ready, responder: @escaping @Sendable (AIRequest, Int) async throws -> String) {
        self.id = id
        self.displayName = id
        self.state = availability
        self.responder = responder
    }

    var requests: [AIRequest] { lock.withLock { log } }

    func availability(refresh: Bool) async -> AIAvailability { lock.withLock { state } }
    func models() async -> [String] { ["fast-model"] }

    func complete(_ request: AIRequest) async throws -> String {
        let index = lock.withLock { () -> Int in
            log.append(request)
            return log.count
        }
        return try await responder(request, index)
    }
}

/// Answers a triage request with one verdict per `ref="…"` in the input.
func triageAnswer(_ request: AIRequest, category: String = "people", needsReply: Bool = true, project: String? = nil) -> String {
    let refs = refsIn(request.input)
    let items = refs.map { ref -> String in
        let projectValue = project.map { "\"\($0)\"" } ?? "null"
        return #"{"threadKey":"\#(ref)","category":"\#(category)","needsReply":\#(needsReply),"priority":2,"summary":"Summary \#(ref)","project":\#(projectValue)}"#
    }
    return #"{"items":[\#(items.joined(separator: ","))]}"#
}

func refsIn(_ text: String) -> [String] {
    let pattern = try! NSRegularExpression(pattern: #"<thread ref="(\d+)">"#)
    return pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
        Range($0.range(at: 1), in: text).map { String(text[$0]) }
    }
}

let testNow = Date(timeIntervalSince1970: 1_800_000_000)
let me = Account(email: "alex@kiteworks.dev")

struct TestMail {
    var id: String
    var thread: String
    var from: String = "ethan.brooks@gmail.com"
    var to: String = me.email
    var subject: String = "Hello"
    var body: String = "Can we talk tomorrow?"
    var daysAgo: Double = 1
    var labels: [String] = [SystemLabel.inbox]
}

func makeDatabase(_ mails: [TestMail], settings: AISettings? = AISettings(enabled: true, provider: "codex")) throws -> AppDatabase {
    let database = try AppDatabase.inMemory()
    let store = MailStore(database)
    try store.upsertAccount(me)
    try store.upsertMessages(mails.map { mail in
        let fromMe = mail.from == me.email
        return MailMessage(
            accountId: me.id, id: mail.id, threadId: mail.thread, date: testNow.addingTimeInterval(-mail.daysAgo * 86_400),
            fromName: fromMe ? "Alex Morgan" : "Ethan Brooks", fromEmail: mail.from, toList: [Participant(email: mail.to)],
            subject: mail.subject, snippet: String(mail.body.prefix(140)), bodyText: mail.body, bodyState: .full,
            labelIds: fromMe ? [SystemLabel.sent] : mail.labels, isFromMe: fromMe)
    })
    if let settings {
        try database.writer.write { db in try settings.write(db) }
    }
    return database
}

func aiRows(_ database: AppDatabase) throws -> [String: ThreadAI] {
    try database.reader.read { db in
        Dictionary(uniqueKeysWithValues: try ThreadAI.fetchAll(db).map { ($0.threadId, $0) })
    }
}
