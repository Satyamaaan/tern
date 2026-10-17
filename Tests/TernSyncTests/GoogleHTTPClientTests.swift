import Foundation
import Synchronization
import Testing
@testable import TernSync

@Suite struct GoogleHTTPClientTests {
    // MARK: Error mapping

    @Test func unauthorizedRefreshesOnceThenFails() async throws {
        let server = StubServer { _ in .error(401, message: "Invalid Credentials") }
        let tokens = CountingTokens()
        let client = makeClient(server, clock: TestClock(), tokens: tokens)
        await #expect(throws: GmailAPIError.unauthorized) { try await client.profile() }
        #expect(server.requests.map { $0.header("Authorization") } == ["Bearer token-1", "Bearer token-2"])
        #expect(await tokens.invalidated == ["token-1", "token-2"])
    }

    @Test func unauthorizedThenSuccess() async throws {
        let server = StubServer { request in
            request.header("Authorization") == "Bearer token-1"
                ? .error(401) : .json(#"{"emailAddress":"me@example.com","historyId":"42"}"#)
        }
        let profile = try await makeClient(server, clock: TestClock()).profile()
        #expect(profile == GmailProfile(emailAddress: "me@example.com", historyId: "42"))
    }

    @Test func historyNotFoundMeansExpired() async throws {
        let server = StubServer { _ in .error(404, message: "Requested entity was not found.") }
        let client = makeClient(server, clock: TestClock())
        await #expect(throws: GmailAPIError.historyExpired) { try await client.history(startHistoryId: "1", pageToken: nil) }
        await #expect(throws: GmailAPIError.notFound) { try await client.deleteLabel(id: "Label_1") }
        let request = try #require(server.requests.first)
        #expect(request.url.path == "/gmail/v1/users/me/history")
        #expect(request.query["startHistoryId"] == "1")
    }

    @Test func otherErrors() async throws {
        let responses: [(StubResponse, GmailAPIError)] = [
            (.error(403, reason: "insufficientPermissions"), .unauthorized),
            (.error(400, message: "Invalid label"), .server(status: 400, message: "Invalid label")),
            (.error(403, reason: "dailyLimitExceeded"), .rateLimited(retryAfter: nil)),
        ]
        for (response, expected) in responses {
            let server = StubServer { _ in response }
            await #expect(throws: expected) { try await makeClient(server, clock: TestClock()).labels() }
            #expect(server.requests.count == 1)
        }
        let offline = StubServer { _ in throw URLError(.notConnectedToInternet) }
        await #expect {
            try await makeClient(offline, clock: TestClock()).labels()
        } throws: { error in
            if case GmailAPIError.network = error { return true }
            return false
        }
    }

    // MARK: Retries

    @Test func serverErrorsBackOffExponentially() async throws {
        let calls = Mutex(0)
        let server = StubServer { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            return n <= 2 ? .error(503, message: "Backend Error") : .json(#"{"labels":[{"id":"INBOX","name":"INBOX"}]}"#)
        }
        let clock = TestClock()
        let labels = try await makeClient(server, clock: clock).labels()
        #expect(labels.map(\.id) == ["INBOX"])
        // base 1 s · 2^n with jitter fixed at the midpoint (×0.75).
        #expect(clock.sleeps == [0.75, 1.5])
    }

    @Test func rateLimitHonoursRetryAfter() async throws {
        let calls = Mutex(0)
        let server = StubServer { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 1 ? .error(429, headers: ["Retry-After": "3"]) : .json(#"{"emailAddress":"a@b.c","historyId":"1"}"#)
        }
        let clock = TestClock()
        _ = try await makeClient(server, clock: clock).profile()
        // The limiter pauses everyone for the same 3 s, so the next acquire does not wait again.
        #expect(clock.sleeps == [3])
    }

    @Test func rateLimit403IsRetried() async throws {
        let calls = Mutex(0)
        let server = StubServer { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 1 ? .error(403, reason: "userRateLimitExceeded") : .json(#"{"sendAs":[]}"#)
        }
        let clock = TestClock()
        #expect(try await makeClient(server, clock: clock).sendAs().isEmpty)
        #expect(clock.sleeps == [0.75])
    }

    @Test func sendIsNotRetriedAfterAServerError() async throws {
        let calls = Mutex(0)
        let server = StubServer { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 1 ? .error(429) : .error(503, message: "Backend Error")
        }
        let clock = TestClock()
        let client = makeClient(server, clock: clock)
        // 429 means Gmail refused the send, so it is retried; a 503 might have sent it, so it isn't.
        await #expect(throws: GmailAPIError.server(status: 503, message: "Backend Error")) {
            try await client.send(raw: Data("x".utf8), threadId: nil)
        }
        #expect(server.requests.count == 2)
        await #expect(throws: GmailAPIError.server(status: 503, message: "Backend Error")) {
            try await client.sendDraft(id: "r1")
        }
        #expect(server.requests.count == 3)
    }

    @Test func newStyleRateLimitReasonsAreRetried() async throws {
        let calls = Mutex(0)
        let server = StubServer { _ in
            let n = calls.withLock { $0 += 1; return $0 }
            return n == 1
                ? .json(#"{"error":{"code":403,"status":"PERMISSION_DENIED","details":[{"reason":"RATE_LIMIT_EXCEEDED"}]}}"#, status: 403)
                : .json(#"{"labels":[]}"#)
        }
        #expect(try await makeClient(server, clock: TestClock()).labels().isEmpty)
        #expect(server.requests.count == 2)
    }

    @Test func longRetryAfterIsReturnedToTheCaller() async throws {
        let server = StubServer { _ in .error(429, headers: ["Retry-After": "600"]) }
        let clock = TestClock()
        await #expect(throws: GmailAPIError.rateLimited(retryAfter: 600)) {
            try await makeClient(server, clock: clock).labels()
        }
        #expect(server.requests.count == 1)
        #expect(clock.sleeps.isEmpty)
    }

    @Test func retriesAreBounded() async throws {
        let server = StubServer { _ in .error(500, message: "boom") }
        let clock = TestClock()
        let client = makeClient(server, clock: clock, options: .init(retry: GmailRetryPolicy(maxAttempts: 4, maxDelay: 2)))
        await #expect(throws: GmailAPIError.server(status: 500, message: "boom")) { try await client.labels() }
        #expect(server.requests.count == 4)
        #expect(clock.sleeps == [0.75, 1.5, 1.5])
    }

    @Test func retryAfterAcceptsHTTPDates() {
        let now: TimeInterval = 1_800_000_000
        let date = Date(timeIntervalSince1970: now + 30)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        #expect(GmailResponseDisposition.parseRetryAfter(formatter.string(from: date), now: now) == 30)
        #expect(GmailResponseDisposition.parseRetryAfter("12", now: now) == 12)
        #expect(GmailResponseDisposition.parseRetryAfter("soon", now: now) == nil)
    }

    // MARK: Requests

    @Test func messageIdsEncodesQueryAndSpamTrash() async throws {
        let server = StubServer { _ in .json(#"{"messages":[{"id":"a","threadId":"t"}],"nextPageToken":"p2"}"#) }
        let client = makeClient(server, clock: TestClock())
        let page = try await client.messageIds(query: "from:a+b@x.com is:unread", labelIds: ["INBOX", "Label_7"],
                                               pageToken: "p1", maxResults: 100)
        #expect(page.messages == [GmailMessageRef(id: "a", threadId: "t")])
        #expect(page.nextPageToken == "p2")
        _ = try await client.messageIds(query: nil, labelIds: ["TRASH"], pageToken: nil, maxResults: 9999)

        let first = server.requests[0]
        #expect(first.url.path == "/gmail/v1/users/me/messages")
        let query = try #require(first.url.query)
        #expect(query.contains("q=from%3Aa%2Bb%40x.com%20is%3Aunread"))
        #expect(query.contains("labelIds=INBOX&labelIds=Label_7"))
        #expect(!query.contains("includeSpamTrash"))
        #expect(server.requests[1].query["includeSpamTrash"] == "true")
        #expect(server.requests[1].query["maxResults"] == "500")
    }

    @Test func sendEncodesRawAsBase64URL() async throws {
        let server = StubServer { _ in .json(#"{"id":"m9","threadId":"t9","labelIds":["SENT"]}"#) }
        let raw = Data("Subject: ?>?\r\n\r\nÿ binary-ish \u{FF}\u{FE}".utf8)
        let ref = try await makeClient(server, clock: TestClock()).send(raw: raw, threadId: "t9")
        #expect(ref == GmailMessageRef(id: "m9", threadId: "t9"))

        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")
        let json = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: String])
        #expect(json["threadId"] == "t9")
        let encoded = try #require(json["raw"])
        #expect(!encoded.contains("+") && !encoded.contains("/") && !encoded.contains("="))
        #expect(Data(base64URLEncoded: encoded) == raw)
    }

    @Test func largeMessagesUseMediaUpload() async throws {
        let server = StubServer { request in
            request.url.path.contains("drafts") ? .json(#"{"id":"r1","message":{"id":"m1","threadId":"t1"}}"#)
                : .json(#"{"id":"m1","threadId":"t1"}"#)
        }
        let raw = Data(repeating: UInt8(ascii: "x"), count: 2048)
        let client = makeClient(server, clock: TestClock(), options: .init(uploadThreshold: 1024))
        _ = try await client.send(raw: raw, threadId: nil)
        _ = try await client.send(raw: raw, threadId: "t1")
        let draft = try await client.updateDraft(id: "r1", raw: raw, threadId: "t1")
        #expect(draft.id == "r1")

        let media = server.requests[0]
        #expect(media.url.absoluteString == "https://gmail.googleapis.com/upload/gmail/v1/users/me/messages/send?uploadType=media")
        #expect(media.header("Content-Type") == "message/rfc822")
        #expect(media.body == raw)

        let multipart = server.requests[1]
        #expect(multipart.url.query == "uploadType=multipart")
        let contentType = try #require(multipart.header("Content-Type"))
        #expect(contentType.hasPrefix("multipart/related; boundary="))
        let parts = try MultipartReader.split(multipart.body, boundary: try #require(GmailBatch.boundary(fromContentType: contentType)))
        #expect(parts.count == 2)
        let (metaHeaders, metadata) = MultipartReader.headersAndBody(parts[0])
        #expect(metaHeaders["Content-Type"] == "application/json; charset=UTF-8")
        #expect(String(decoding: metadata, as: UTF8.self) == #"{"threadId":"t1"}"#)
        let (rawHeaders, rawBody) = MultipartReader.headersAndBody(parts[1])
        #expect(rawHeaders["Content-Type"] == "message/rfc822")
        #expect(rawBody == raw)

        let update = server.requests[2]
        #expect(update.method == "PUT")
        #expect(update.url.path == "/upload/gmail/v1/users/me/drafts/r1")
        #expect(update.bodyText.contains(#""id":"r1""#))
    }

    @Test func draftsUseJSONBodies() async throws {
        let server = StubServer { request in
            switch (request.method, request.url.path) {
            case ("POST", "/gmail/v1/users/me/drafts/send"): .json(#"{"id":"m2","threadId":"t2"}"#)
            case ("DELETE", _): StubResponse(status: 204)
            default: .json(#"{"id":"r2","message":{"id":"m2","threadId":"t2"}}"#)
            }
        }
        let client = makeClient(server, clock: TestClock())
        let draft = try await client.createDraft(raw: Data("hi".utf8), threadId: nil)
        #expect(draft == GmailDraft(id: "r2", message: GmailMessage(id: "m2", threadId: "t2")))
        #expect(try await client.sendDraft(id: "r2") == GmailMessageRef(id: "m2", threadId: "t2"))
        try await client.deleteDraft(id: "r2")

        let create = try JSONSerialization.jsonObject(with: server.requests[0].body) as? [String: Any]
        let message = create?["message"] as? [String: Any]
        #expect(message?["raw"] as? String == Data("hi".utf8).base64URLEncodedString())
        #expect(message?["threadId"] == nil)
        #expect(server.requests[1].bodyText == #"{"id":"r2"}"#)
        #expect(server.requests[2].url.path == "/gmail/v1/users/me/drafts/r2")
    }

    @Test func batchModifySplitsAtOneThousand() async throws {
        let server = StubServer { _ in StubResponse(status: 204) }
        let client = makeClient(server, clock: TestClock())
        try await client.batchModify(messageIds: (0..<2500).map { "m\($0)" }, add: ["STARRED"], remove: ["UNREAD"])
        try await client.batchModify(messageIds: [], add: ["STARRED"], remove: [])
        #expect(server.requests.count == 3)
        let sizes = try server.requests.map { request -> Int in
            let body = try #require(try JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            #expect(body["addLabelIds"] as? [String] == ["STARRED"])
            #expect(body["removeLabelIds"] as? [String] == ["UNREAD"])
            return (body["ids"] as? [String])?.count ?? 0
        }
        #expect(sizes == [1000, 1000, 500])
    }

    @Test func attachmentIsDecoded() async throws {
        let bytes = Data((0..<255).map(UInt8.init))
        let server = StubServer { _ in .json(#"{"size":255,"data":"\#(bytes.base64URLEncodedString())"}"#) }
        let data = try await makeClient(server, clock: TestClock()).attachment(messageId: "m1", attachmentId: "ANGjdJ_x-1")
        #expect(data == bytes)
        #expect(server.requests.first?.url.path == "/gmail/v1/users/me/messages/m1/attachments/ANGjdJ_x-1")
    }

    @Test func threadAndLabelEndpoints() async throws {
        let server = StubServer { request in
            request.url.path.hasSuffix("/labels") && request.method == "POST"
                ? .json(#"{"id":"Label_9","name":"Clients/Acme","type":"user"}"#) : .json("{}")
        }
        let client = makeClient(server, clock: TestClock())
        let label = try await client.createLabel(name: "Clients/Acme")
        #expect(label.id == "Label_9")
        try await client.trashThread(id: "t1")
        try await client.untrashThread(id: "t1")
        #expect(server.requests.map { "\($0.method) \($0.url.path)" } == [
            "POST /gmail/v1/users/me/labels",
            "POST /gmail/v1/users/me/threads/t1/trash",
            "POST /gmail/v1/users/me/threads/t1/untrash",
        ])
        #expect(server.requests[0].bodyText.contains(#""name":"Clients\/Acme""#))
    }

    // MARK: Rate limiter

    @Test func rateLimiterPacesSpending() async throws {
        let clock = TestClock()
        let limiter = GmailRateLimiter(unitsPerMinute: 6000, clock: clock.clock)
        // A safety net: the bucket holds 2,000 units and refills at the full 100 a second.
        try await limiter.acquire(2000)
        #expect(clock.sleeps.isEmpty)
        #expect(await limiter.delay(for: 200) == 2)
        try await limiter.acquire(200)
        #expect(clock.sleeps == [2])
        await limiter.pause(for: 10)
        try await limiter.acquire(1)
        #expect(clock.sleeps.count == 2)
        #expect(abs(clock.sleeps[1] - 10) < 0.05)
    }

    @Test func pauseHoldsCallersAlreadyWaiting() async throws {
        let virtual = TestClock()
        let limiter = Locked<GmailRateLimiter?>(nil)
        let paused = Locked(false)
        // On the first wait, a 429 elsewhere pauses everyone for 30 s.
        let clock = GoogleClock(now: { virtual.now }, sleep: { seconds in
            try await virtual.clock.sleep(seconds)
            if !paused.value, let limiter = limiter.value {
                paused.set(true)
                await limiter.pause(for: 30)
            }
        }, random: { 0.5 })
        limiter.set(GmailRateLimiter(unitsPerMinute: 6000, clock: clock))
        try await limiter.value!.acquire(2100)  // 100 units of debt: 1 s
        #expect(virtual.sleeps.count == 2)
        #expect(virtual.sleeps[0] == 1)
        #expect(abs(virtual.sleeps[1] - 30) < 0.01)
    }
}
