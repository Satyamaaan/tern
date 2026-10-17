import Foundation
import GRDB
import Testing
@testable import Tern
@testable import TernCore

/// What opening a thread costs on the main thread with nothing cached: the detail read (the reader's
/// observation starts with `.immediate` scheduling) and building the payload, which sanitizes the
/// expanded message when it is small (`ReaderPayload.inlineSanitizeLimit`). Budget for j/k: 50 ms.
/// Prints numbers; skipped with TERN_SKIP_PERF=1.
@MainActor
@Suite("Reader open cost", .serialized)
struct ReaderOpenCost {
    static let skip = ProcessInfo.processInfo.environment["TERN_SKIP_PERF"] == "1"
    let account = Account(email: "me@example.com")

    func store() throws -> (MailStore, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tern-open-cost-\(UUID().uuidString)")
        let database = try AppDatabase.open(at: directory.appendingPathComponent("Tern.sqlite"))
        let store = MailStore(database)
        try store.upsertAccount(account)
        return (store, directory)
    }

    func context() -> ReaderContext {
        ReaderContext(accountEmails: [account.email], accountColorIndex: 0, labelNames: [:], trust: ReaderTrust(), summary: [:])
    }

    /// Best of five cold opens (fresh message ids each time, so no sanitized body is cached).
    func measure(_ store: MailStore, _ make: (Int) throws -> ThreadKey) throws -> (read: Double, payload: Double, bytes: Int) {
        var best = (read: Double.infinity, payload: Double.infinity, bytes: 0)
        for round in 0..<5 {
            let key = try make(round)
            let start = CFAbsoluteTimeGetCurrent()
            let detail = try #require(try store.threadDetail(key))
            let read = CFAbsoluteTimeGetCurrent()
            _ = ReaderPayload.make(detail, context: context())
            _ = ReaderPayload.signature(detail, context: context())
            let done = CFAbsoluteTimeGetCurrent()
            let bytes = detail.messages.reduce(0) { $0 + ReaderPayload.bodyLength($1) }
            best = (min(best.read, (read - start) * 1000), min(best.payload, (done - read) * 1000), bytes)
        }
        return best
    }

    @Test(.enabled(if: !skip, "TERN_SKIP_PERF=1"))
    func longThreadAndBigNewsletter() throws {
        let (store, directory) = try store()
        defer { try? FileManager.default.removeItem(at: directory) }

        // 150 replies, each quoting the one before (Gmail-style), capped at 60 KB a message.
        let long = try measure(store) { round in
            var messages: [MailMessage] = []
            var quoted = ""
            for index in 0..<150 {
                let html = "<div dir=\"ltr\">Reply \(index): " + String(repeating: "Some thoughts on the plan. ", count: 20)
                    + "</div><div class=\"gmail_quote\"><blockquote class=\"gmail_quote\">\(quoted)</blockquote></div>"
                quoted = String(html.prefix(60_000))
                messages.append(MailMessage(
                    accountId: account.id, id: "l\(round)-\(index)", threadId: "long-\(round)",
                    date: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 600), fromName: "Ann",
                    fromEmail: index.isMultiple(of: 2) ? "ann@example.com" : account.email, subject: "Plan",
                    snippet: "Reply \(index)", bodyText: "Reply \(index)", bodyHtml: html, bodyState: .full,
                    labelIds: index == 149 ? ["INBOX", "UNREAD"] : ["INBOX"]))
            }
            try store.upsertMessages(messages)
            return ThreadKey(accountId: account.id, threadId: "long-\(round)")
        }

        // One ~3 MB newsletter: a long table of styled rows with images and links.
        let newsletter = try measure(store) { round in
            var html = "<html><head><style>.row td { padding: 8px; color: #333 } a { color: #5b4bdb }</style></head><body><table width=\"600\">"
            var index = 0
            while html.utf8.count < 3_000_000 {
                html += "<tr class=\"row\"><td style=\"padding:8px;color:#333;font:14px/20px Helvetica\"><a href=\"https://example.com/item/\(index)?utm_source=news\">Item \(index): a headline that runs a little long</a>"
                    + "<img src=\"https://cdn.example/\(index).png\" width=\"40\" height=\"40\" alt=\"\"><p>Summary text for the item, two lines or so of copy.</p></td></tr>"
                index += 1
            }
            html += "</table></body></html>"
            try store.upsertMessages([MailMessage(
                accountId: account.id, id: "n\(round)", threadId: "news-\(round)", date: Date(), fromName: "News",
                fromEmail: "news@example.com", subject: "Weekly", snippet: "Weekly", bodyText: "Weekly", bodyHtml: html,
                bodyState: .full, labelIds: ["INBOX", "UNREAD"])])
            return ThreadKey(accountId: account.id, threadId: "news-\(round)")
        }

        print(String(format: "reader cold open, long thread (150 messages, %.1f MB): detail read %.1f ms, payload + sanitize %.1f ms",
                     Double(long.bytes) / 1_048_576, long.read, long.payload))
        print(String(format: "reader cold open, newsletter (%.1f MB): detail read %.1f ms, payload + sanitize %.1f ms",
                     Double(newsletter.bytes) / 1_048_576, newsletter.read, newsletter.payload))
        // Debug-build numbers; the j/k budget for the whole open, paint included, is 50 ms.
        #expect(long.read + long.payload < 50)
        #expect(newsletter.read + newsletter.payload < 50, "a big body is sanitized off the main thread")
    }
}
