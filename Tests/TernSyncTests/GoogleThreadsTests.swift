import Foundation
import Synchronization
import Testing
@testable import TernSync

/// The thread ids a batch request asks for, in part order.
private func batchThreadIds(_ request: StubRequest) -> [String] {
    request.bodyText.components(separatedBy: "\r\n")
        .filter { $0.hasPrefix("GET /gmail/v1/users/me/threads/") }
        .map { line in String(line.dropFirst("GET /gmail/v1/users/me/threads/".count).prefix { $0 != "?" }) }
}

private func threadJSON(_ id: String, messages: Int = 2) -> String {
    let items = (0..<messages).map { messageJSON("\(id)-m\($0)", thread: id) }.joined(separator: ",")
    return #"{"id":"\#(id)","historyId":"200","messages":[\#(items)]}"#
}

@Suite struct GoogleThreadsTests {
    @Test func threadsAreFetchedThroughTheBatchEndpoint() async throws {
        let server = StubServer { request in
            batchResponse(batchThreadIds(request).enumerated().reversed().map { index, id in
                id == "gone" ? (index, 404, #"{"error":{"code":404,"message":"Requested entity was not found."}}"#)
                    : (index, 200, threadJSON(id))
            })
        }
        let threads = try await makeClient(server, clock: TestClock()).threads(ids: ["t1", "gone", "t2", "t1"], format: .full)

        #expect(threads.map(\.id) == ["t1", "t2"])
        #expect(threads.first?.messages?.map(\.id) == ["t1-m0", "t1-m1"])
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.url.absoluteString == "https://gmail.googleapis.com/batch/gmail/v1")
        #expect(request.bodyText.contains("GET /gmail/v1/users/me/threads/t1?format=full\r\n"))
        #expect(batchThreadIds(request) == ["t1", "gone", "t2"])
    }

    @Test func threadsRetryFailedPartsAndSplitLargeRequests() async throws {
        let round = Mutex(0)
        let server = StubServer { request in
            let ids = batchThreadIds(request)
            let n = round.withLock { $0 += 1; return $0 }
            return batchResponse(ids.enumerated().map { index, id in
                n == 1 && id == "t3" ? (index, 503, #"{"error":{"code":503,"message":"Backend Error"}}"#) : (index, 200, threadJSON(id, messages: 1))
            })
        }
        let clock = TestClock()
        let ids = (0..<60).map { "t\($0)" }
        let client = makeClient(server, clock: clock, options: .init(maxConcurrentBatches: 1))
        let threads = try await client.threads(ids: ids, format: .metadata)

        #expect(threads.map(\.id) == ids)
        #expect(server.requests.map { batchThreadIds($0).count } == [50, 1, 10])
        #expect(server.requests.allSatisfy { $0.bodyText.contains("?format=metadata") })
        #expect(clock.sleeps.count == 1)
    }

    @Test func threadsGetIsChargedPerThread() async throws {
        let server = StubServer { request in
            batchResponse(batchThreadIds(request).enumerated().map { ($0.offset, 200, threadJSON($0.element)) })
        }
        let clock = TestClock()
        // A bucket of exactly two full threads: the third waits for the refill.
        let limiter = GmailRateLimiter(unitsPerMinute: 6000, burst: 240, clock: clock.clock)
        let client = GmailHTTPClient(tokens: CountingTokens(), session: server.session, rateLimiter: limiter,
                                     clock: clock.clock, options: .init(maxConcurrentBatches: 1, batchSize: 2))
        _ = try await client.threads(ids: ["a", "b"], format: .full)
        #expect(clock.sleeps.isEmpty)
        _ = try await client.threads(ids: ["c"], format: .raw)
        #expect(clock.sleeps.count == 1 && abs(clock.sleeps[0] - 1.2) < 0.001)
        #expect(server.requests.last?.bodyText.contains("threads/c?format=full") == true)
    }

    @Test func draftsAreListedWithAQuery() async throws {
        let server = StubServer { _ in
            .json(#"{"drafts":[{"id":"r-1","message":{"id":"m-1","threadId":"t-1"}}],"resultSizeEstimate":1}"#)
        }
        let page = try await makeClient(server, clock: TestClock())
            .drafts(query: "rfc822msgid:tern.abc@example.com", pageToken: "p2", maxResults: 5)

        #expect(page.drafts == [GmailDraft(id: "r-1", message: GmailMessage(id: "m-1", threadId: "t-1"))])
        let request = try #require(server.requests.first)
        #expect(request.method == "GET")
        #expect(request.url.path == "/gmail/v1/users/me/drafts")
        #expect(request.query == ["q": "rfc822msgid:tern.abc@example.com", "pageToken": "p2", "maxResults": "5"])
    }

    @Test func fakeGmailFindsDraftsByMessageId() async throws {
        let fake = FakeGmail(email: "me@example.com", sleep: { _ in })
        let raw = Data("Message-ID: <tern.one@example.com>\r\nSubject: Hi\r\n\r\nBody".utf8)
        let created = try await fake.createDraft(raw: raw, threadId: nil)
        _ = try await fake.createDraft(raw: Data("Subject: Other\r\n\r\nBody".utf8), threadId: nil)

        let page = try await fake.drafts(query: "rfc822msgid:tern.one@example.com", pageToken: nil, maxResults: 10)
        #expect(page.drafts?.map(\.id) == [created.id])
        #expect(try await fake.drafts(query: nil, pageToken: nil, maxResults: 10).drafts?.count == 2)
    }
}
