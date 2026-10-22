import Foundation
import GRDB
import Testing
@testable import TernAI
import TernCore

struct LedgerResolutionTests {
    static let cases: [(String, String, Bool, Bool, Bool)] = [
        ("Thanks for the call.", "fulfilled", true, true, false),
        ("I haven't sent the revised deck.", "fulfilled", true, true, false),
        ("I couldn't finish it. Here is the revised deck.", "fulfilled", true, true, false),
        ("I didn't send the revised deck.", "fulfilled", true, true, false),
        ("I have not sent the revised deck.", "fulfilled", true, true, false),
        ("I never sent the revised deck.", "fulfilled", true, true, false),
        ("I forgot to send it. Here is the revised deck.", "fulfilled", true, true, false),
        ("I was unable to finish it. Here is the revised deck.", "fulfilled", true, true, false),
        ("Here is the revised deck, yet incomplete.", "fulfilled", true, true, false),
        ("Here is the revised deck, still incomplete.", "fulfilled", true, true, false),
        ("Have I sent the revised deck?", "fulfilled", true, true, false),
        ("Here is the draft revised deck.", "fulfilled", true, true, false),
        ("Here is the preliminary revised deck.", "fulfilled", true, true, false),
        ("Here is the WIP revised deck.", "fulfilled", true, true, false),
        ("Here is the rough revised deck.", "fulfilled", true, true, false),
        ("Here is the first pass revised deck.", "fulfilled", true, true, false),
        ("Thanks for the update.", "fulfilled", true, false, false),
        ("I will send the revised deck tomorrow.", "fulfilled", true, false, false),
        ("The revised deck is partially finished, still working on it.", "fulfilled", true, false, false),
        ("Here is the revised deck for your review.", "fulfilled", true, false, true),
        ("Attached is the revised deck.pptx.", "fulfilled", true, true, true),
        ("Here is the file for your review.", "fulfilled", true, true, true),
        ("The revised deck request is withdrawn. We no longer need it.", "withdrawn", false, false, true),
        ("Here is the revised deck for your review.", "fulfilled", false, false, false),
        ("I will send the revised deck next Friday instead.", "open", true, false, false),
    ]

    static func fixture(_ body: String, mine: Bool = true, attachment: Bool = false) throws -> (AppDatabase, [PromptThread], [Commitment]) {
        let person = "maya@example.com"
        let db = try makeDatabase([
            TestMail(id: "source", thread: "resolution", from: me.email, to: person, body: "I'll send the revised deck by Thursday.", daysAgo: 4),
            TestMail(id: "later", thread: "resolution", from: mine ? me.email : person, to: mine ? person : me.email, body: body, daysAgo: 1)
        ])
        let key = ThreadKey(accountId: me.id, threadId: "resolution")
        try db.writer.write { db in
            try Ledger.applyExtraction(db, key: key, items: [LedgerExtraction(direction: .iOwe, counterparty: person,
                deliverable: "Send revised deck", sourceMessageId: "source", quote: "I'll send the revised deck by Thursday.",
                sourceDate: testNow.addingTimeInterval(-4 * 86_400), dueAt: nil, dueText: nil, confidence: 2, existingId: nil)],
                messageCount: 2, promptVersion: Prompts.ledgerVersion, origin: "codex", now: testNow)
            if attachment { try MailAttachment(accountId: me.id, messageId: "later", partId: "1", filename: "revised-deck.pptx", mimeType: "application/octet-stream", size: 100).insert(db) }
        }
        let values = try db.reader.read { db in
            (try PromptData.threads(db, keys: [key], messages: 12, characters: 2000), try Commitment.filter(Column("origin") == "codex").fetchAll(db))
        }
        var threads = values.0
        if attachment, let i = threads.first?.messages.firstIndex(where: { $0.id == "later" }) {
            threads[0].messages[i].text += "\nAttachments: revised-deck.pptx"
        }
        return (db, threads, values.1)
    }
    static func answer(_ item: Commitment, status: String, quote: String, ref: String? = nil) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: ["items": [["ref": "c\(item.id!)", "status": status,
            "resolvedByRef": ref ?? "c\(item.id!).m1", "quote": quote]]]), encoding: .utf8)!
    }

    @Test(arguments: cases.indices) func validatesEvidence(_ index: Int) throws {
        let (body, status, mine, attachment, done) = Self.cases[index]
        let (database, threads, items) = try Self.fixture(body, mine: mine, attachment: attachment)
        let item = try #require(items.first)
        let result = try database.writer.write { db in
            try LedgerResolution.apply(Self.answer(item, status: status, quote: body), db: db, threads: threads, items: items, now: testNow)
        }
        #expect(result == (done ? 1 : 0))
        let stored = try #require(database.reader.read { try Commitment.fetchOne($0, key: item.id) })
        #expect(stored.state == (done ? .done : .open))
        #expect(stored.checkedCount == 2)
        #expect(stored.stateSource == "ai")
    }

    @Test(arguments: ["bad-status", "invalid-json"]) func invalidResolutionAdvances(_ output: String) async throws {
        let (database, threads, items) = try Self.fixture("Thanks for the update.")
        let item = try #require(items.first)
        let text = output == "invalid-json" ? "oops" : Self.answer(item, status: "bad", quote: "Thanks for the update.")
        let provider = FakeProvider { _, _ in text }
        let queue = LedgerQueue(database: database, providers: AIProviders([provider]), now: { testNow })
        #expect(try await queue.processBatch().sent == 1)
        #expect(try await queue.processBatch().sent == 0)
        #expect(provider.requests.count == 1)
        #expect(try await database.reader.read { try Commitment.fetchOne($0, key: item.id)?.checkedCount } == threads[0].messageCount)
    }

    @Test func quoteCannotOmitDraftQualifier() throws {
        let (database, threads, items) = try Self.fixture("This is a draft. Here is the revised deck for your review.")
        let item = try #require(items.first)
        let result = try database.writer.write { db in
            try LedgerResolution.apply(Self.answer(item, status: "fulfilled", quote: "Here is the revised deck for your review."), db: db, threads: threads, items: items, now: testNow)
        }
        #expect(result == 0)
    }

    @Test func userLockAndUnknownCitation() throws {
        let (database, threads, items) = try Self.fixture("Here is the revised deck for your review.")
        let item = try #require(items.first)
        try database.writer.write { db in
            #expect(try LedgerResolution.apply(Self.answer(item, status: "fulfilled", quote: "Here is the revised deck for your review.", ref: "unknown"), db: db, threads: threads, items: items, now: testNow) == 0)
            _ = try MailStore.setCommitmentState(db, [item.id!], to: .open, now: testNow)
            #expect(try LedgerResolution.apply(Self.answer(item, status: "fulfilled", quote: "Here is the revised deck for your review."), db: db, threads: threads, items: items, now: testNow) == 0)
            #expect(try Commitment.fetchOne(db, key: item.id)?.stateSource == "user")
        }
    }

    @Test func strictSchemaAndLaterOnlyInput() throws {
        let (_, threads, items) = try Self.fixture("Thanks for the update.")
        let request = LedgerResolution.request(threads, items: items)
        let schema = try JSONSerialization.jsonObject(with: Data(request.schema!.utf8))
        func walk(_ node: Any) {
            if let object = node as? [String: Any] {
                if object["type"] as? String == "object" {
                    #expect(object["additionalProperties"] as? Bool == false)
                    #expect(Set(object["required"] as? [String] ?? []) == Set((object["properties"] as? [String: Any] ?? [:]).keys))
                }
                object.values.forEach(walk)
            } else if let array = node as? [Any] { array.forEach(walk) }
        }
        walk(schema)
        #expect(request.input.components(separatedBy: "<message ref=").count == 2)
        #expect(request.isBackground)
    }

    @Test func queueDoesNotReaskUntilThreadGrowsAndSharesCap() async throws {
        let (database, _, items) = try Self.fixture("Thanks for the update.")
        let item = try #require(items.first)
        let provider = FakeProvider { _, _ in Self.answer(item, status: "open", quote: "Thanks for the update.") }
        let queue = LedgerQueue(database: database, providers: AIProviders([provider]), now: { testNow })
        #expect(try await queue.processBatch().sent == 1)
        #expect(try await queue.processBatch().sent == 0)
        #expect(provider.requests.count == 1)
        let (capped, _, _) = try Self.fixture("Thanks for the update.")
        try await capped.writer.write { try Setting(key: "ledger.aiDailyCalls", value: "0").upsert($0) }
        let cappedQueue = LedgerQueue(database: capped, providers: AIProviders([provider]), now: { testNow })
        #expect(try await cappedQueue.processBatch().sent == 0)
        #expect(provider.requests.count == 1)
    }

}
