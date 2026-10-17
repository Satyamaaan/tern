import Foundation
import Synchronization
import Testing
@testable import TernSync

@Suite struct GoogleBatchTests {
    @Test func batchRequestIsWellFormed() async throws {
        let server = StubServer { request in
            batchResponse(batchIds(request).enumerated().map { ($0.offset, 200, messageJSON($0.element)) })
        }
        let clock = TestClock()
        let messages = try await makeClient(server, clock: clock).messages(ids: ["a1", "b2", "a1"], format: .metadata)

        #expect(messages.map(\.id) == ["a1", "b2"])
        let request = try #require(server.requests.first)
        #expect(server.requests.count == 1)
        #expect(request.method == "POST")
        #expect(request.url.absoluteString == "https://gmail.googleapis.com/batch/gmail/v1")
        #expect(request.header("Authorization") == "Bearer token-1")

        let contentType = try #require(request.header("Content-Type"))
        #expect(contentType.hasPrefix("multipart/mixed; boundary="))
        let boundary = try #require(GmailBatch.boundary(fromContentType: contentType))
        let parts = try MultipartReader.split(request.body, boundary: boundary)
        #expect(parts.count == 2)
        for (index, part) in parts.enumerated() {
            let (headers, http) = MultipartReader.headersAndBody(part)
            #expect(headers["Content-Type"] == "application/http")
            #expect(headers["Content-ID"] == "<item-\(index)>")
            let id = index == 0 ? "a1" : "b2"
            #expect(String(decoding: http, as: UTF8.self).hasPrefix("GET /gmail/v1/users/me/messages/\(id)?format=metadata\r\n"))
        }
        #expect(request.bodyText.hasSuffix("--\(boundary)--\r\n"))
    }

    @Test func mixedBatchRetriesOnlyFailedParts() async throws {
        let round = Mutex(0)
        let server = StubServer { request in
            let ids = batchIds(request)
            let n = round.withLock { $0 += 1; return $0 }
            // Answer out of order: matching must go by Content-ID, not position.
            let parts: [(Int, Int, String)] = ids.enumerated().reversed().map { index, id in
                if n > 1 { return (index, 200, messageJSON(id)) }
                switch id {
                case "m2": return (index, 404, #"{"error":{"code":404,"message":"Requested entity was not found."}}"#)
                case "m3": return (index, 429, #"{"error":{"code":429,"message":"Too many concurrent requests for user."}}"#)
                case "m4": return (index, 503, #"{"error":{"code":503,"message":"Backend Error"}}"#)
                case "m5": return (index, 403, #"{"error":{"code":403,"errors":[{"reason":"userRateLimitExceeded"}]}}"#)
                default: return (index, 200, messageJSON(id))
                }
            }
            return batchResponse(parts)
        }
        let clock = TestClock()
        let messages = try await makeClient(server, clock: clock).messages(ids: ["m1", "m2", "m3", "m4", "m5"], format: .full)

        #expect(messages.map(\.id) == ["m1", "m3", "m4", "m5"])
        #expect(server.requests.count == 2)
        #expect(batchIds(server.requests[1]) == ["m3", "m4", "m5"])
        #expect(clock.sleeps.count == 1)
    }

    @Test func largeRequestsAreSplitIntoBatches() async throws {
        let server = StubServer { request in
            batchResponse(batchIds(request).enumerated().map { ($0.offset, 200, messageJSON($0.element)) })
        }
        let ids = (0..<120).map { "id\($0)" }
        let clock = TestClock()
        let client = makeClient(server, clock: clock, options: .init(maxConcurrentBatches: 2))
        let messages = try await client.messages(ids: ids, format: .minimal)

        #expect(messages.map(\.id) == ids)
        #expect(server.requests.map { batchIds($0).count }.sorted() == [20, 50, 50])
    }

    @Test func innerUnauthorizedRefreshesOnce() async throws {
        let server = StubServer { request in
            let ids = batchIds(request)
            if request.header("Authorization") == "Bearer token-1" {
                return batchResponse(ids.enumerated().map { ($0.offset, 401, #"{"error":{"code":401}}"#) })
            }
            return batchResponse(ids.enumerated().map { ($0.offset, 200, messageJSON($0.element)) })
        }
        let tokens = CountingTokens()
        let clock = TestClock()
        let messages = try await makeClient(server, clock: clock, tokens: tokens).messages(ids: ["x"], format: .full)
        #expect(messages.map(\.id) == ["x"])
        #expect(await tokens.invalidated == ["token-1"])
        #expect(clock.sleeps.isEmpty)
    }

    @Test func persistentRateLimitGivesUp() async throws {
        let server = StubServer { request in
            batchResponse(batchIds(request).enumerated().map { ($0.offset, 429, #"{"error":{"code":429}}"#) })
        }
        let clock = TestClock()
        let client = makeClient(server, clock: clock, options: .init(retry: GmailRetryPolicy(maxAttempts: 3)))
        await #expect(throws: GmailAPIError.rateLimited(retryAfter: nil)) {
            try await client.messages(ids: ["x"], format: .full)
        }
        #expect(server.requests.count == 3)
        #expect(clock.sleeps == [0.75, 1.5])
    }

    @Test func parsesLenientMultipart() throws {
        let body = """
        This preamble is ignored.
        --b0undary
        Content-Type: application/http
        Content-ID: <response-item-1>

        HTTP/1.1 404 Not Found
        Content-Type: application/json

        {"error":{"code":404}}
        --b0undary
        Content-Type: application/http
        Content-ID: response-item-0

        HTTP/1.1 200 OK
        Content-Type: application/json

        {"id":"a","threadId":"t"}
        --b0undary--
        """
        let boundary = try #require(GmailBatch.boundary(fromContentType: #"multipart/mixed; boundary="b0undary""#))
        let parts = try GmailBatch.parse(Data(body.utf8), boundary: boundary)
        #expect(parts.count == 2)
        #expect(parts.map { GmailBatch.index(of: $0) } == [1, 0])
        #expect(parts.map(\.status) == [404, 200])
        #expect(String(decoding: parts[1].body, as: UTF8.self) == #"{"id":"a","threadId":"t"}"#)
        #expect(parts[1].header("content-type") == "application/json")
    }
}
