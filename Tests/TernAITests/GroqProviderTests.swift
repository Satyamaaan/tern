import Foundation
import Testing
@testable import TernAI

private final class GroqStub: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let handler = Self.lock.withLock { Self.handler! }
            let (status, headers, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private func requestBody(_ request: URLRequest) throws -> Data {
    // URLSession may move the body into a stream before handing it to URLProtocol.
    let data: Data
    if let body = request.httpBody { data = body }
    else {
        let stream = try #require(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            result.append(contentsOf: buffer.prefix(count))
        }
        data = result
    }
    return data
}

@Suite(.serialized) struct GroqProviderTests {
    private func provider(_ handler: @escaping (URLRequest) throws -> (Int, [String: String], Data)) -> GroqProvider {
        GroqStub.lock.withLock { GroqStub.handler = handler }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GroqStub.self]
        return GroqProvider(session: URLSession(configuration: config), key: { "test-key" })
    }

    private var answer: Data { Data(#"{"choices":[{"message":{"content":"<think>private reasoning</think> Final answer"}}]}"#.utf8) }

    @Test func requestAndResponse() async throws {
        let answer = answer
        let provider = provider { request in
            #expect(request.url?.absoluteString == "https://api.groq.com/openai/v1/chat/completions")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-key")
            #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
            #expect(request.timeoutInterval == 17)
            let data = try requestBody(request)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["model"] as? String == GroqProvider.defaultModel)
            #expect(body["reasoning_effort"] as? String == "none")
            let messages = try #require(body["messages"] as? [[String: String]])
            #expect(messages == [["role": "system", "content": "instructions"], ["role": "user", "content": "mail"]])
            let format = try #require(body["response_format"] as? [String: Any])
            #expect(format["type"] as? String == "json_schema")
            #expect((format["json_schema"] as? [String: Any])?["strict"] as? Bool == true)
            return (200, [:], answer)
        }
        let schema = #"{"type":"object","properties":{"summary":{"type":"string"}},"required":["summary"],"additionalProperties":false}"#
        #expect(try await provider.complete(AIRequest(instructions: "instructions", input: "mail", schema: schema, timeout: 17)) == "Final answer")
        #expect(await provider.availability(refresh: false) == .ready)
        #expect(await GroqProvider().availability(refresh: false) == .signedOut)
    }

    @Test func fallbackAndCareful() async throws {
        let answer = answer
        let provider = provider { request in
            let data = try requestBody(request)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["model"] as? String == "custom-model")
            #expect(body["reasoning_effort"] == nil)
            #expect((body["response_format"] as? [String: String])?["type"] == "json_object")
            return (200, [:], answer)
        }
        _ = try await provider.complete(AIRequest(instructions: "", input: "", schema: #"{"type":"object","properties":{"a":{"type":"string"}}}"#, model: "custom-model", effort: .careful))
    }

    @Test(arguments: [401, 403, 429, 500]) func errors(status: Int) async {
        let provider = provider { _ in (status, ["Retry-After": "12"], Data()) }
        let expected: AIError = switch status {
        case 401, 403: .notSignedIn(provider: "Groq")
        case 429: .rateLimited("Groq's rate limit was reached. Retry after 12.")
        default: .failed("Groq request failed (HTTP 500).")
        }
        await #expect(throws: expected) { try await provider.complete("test") }
    }

    @Test func timeout() async {
        let provider = provider { _ in throw URLError(.timedOut) }
        await #expect(throws: AIError.timedOut) { try await provider.complete("test") }
    }

    @Test func unusableAnswer() async {
        let provider = provider { _ in (200, [:], Data(#"{"choices":[]}"#.utf8)) }
        await #expect(throws: AIError.invalidOutput("Groq returned no answer.")) { try await provider.complete("test") }
    }

    @Test func strictNestedSchema() {
        let schema: [String: Any] = ["type": "object", "properties": ["items": ["type": "array", "items": ["type": "object", "properties": ["x": ["type": "string"]]]]], "required": ["items"], "additionalProperties": false]
        #expect(!GroqProvider.isStrictSchema(schema))
    }

    @Test func defaultsAndResolution() async throws {
        let database = try makeDatabase([], settings: nil)
        let unset = try await database.reader.read { try AISettings.read($0) }
        #expect(unset.explicitEnabled == nil)
        #expect(unset.isEnabled(groqKeyPresent: true))
        #expect(!unset.isEnabled(groqKeyPresent: false))
        let groq = GroqProvider(key: { "test-key" })
        let cli = FakeProvider(id: "codex") { _, _ in "{}" }
        let providers = AIProviders([cli, groq])
        #expect(try await providers.resolve(unset).id == "groq")
        #expect(try await providers.resolve(AISettings(enabled: true, provider: "codex")).id == "codex")
        let disabled = AISettings(enabled: false)
        try await database.writer.write { try disabled.write($0) }
        #expect(try await database.reader.read { try AISettings.read($0) }.explicitEnabled == false)
        await #expect(throws: AIError.disabled) { try await providers.resolve(disabled) }
    }

    @Test func cliContextUnchanged() {
        #expect(TriageQueue.batchSize(for: "codex") == 30)
        #expect(TriageQueue.batchSize(for: "claude") == 15)
        for id in ["codex", "claude"] {
            #expect(TriageQueue.context(for: id).messages == 2)
            #expect(TriageQueue.context(for: id).characters == 600)
        }
        #expect(TriageQueue.batchSize(for: "groq") == 20)
        #expect(TriageQueue.context(for: "groq").messages == 3)
        #expect(TriageQueue.context(for: "groq").characters == 1_500)
    }
}
