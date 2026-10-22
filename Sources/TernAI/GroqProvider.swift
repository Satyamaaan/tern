import Foundation

/// Fast HTTP model access. The app supplies a Keychain reader; this module never stores credentials.
public struct GroqProvider: AIProvider {
    public let id = "groq"
    public let displayName = "Groq"
    public static let defaultModel = "qwen/qwen3.8-27b"
    private let key: @Sendable () -> String?
    private let session: URLSession
    // Separate from CLIGate.shared: HTTP never competes with CLI processes. Reserve one slot for readers.
    private static let gate = CLIGate(limit: 4, backgroundLimit: 3)

    public init(session: URLSession = .shared, key: @escaping @Sendable () -> String? = { nil }) {
        self.session = session
        self.key = key
    }

    public func availability(refresh: Bool) async -> AIAvailability {
        credential == nil ? .signedOut : .ready
    }

    private var credential: String? {
        guard let value = key()?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }

    public func models() async -> [String] {
        [Self.defaultModel, "qwen/qwen3.6-27b", "openai/gpt-oss-120b", "openai/gpt-oss-20b"]
    }

    public func complete(_ request: AIRequest) async throws -> String {
        try await Self.gate.withSlot(background: request.isBackground) {
            guard let key = credential else { throw AIError.notSignedIn(provider: displayName) }
            var http = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/chat/completions")!)
            http.httpMethod = "POST"
            http.timeoutInterval = request.timeout
            http.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var body: [String: Any] = [
                "model": request.model ?? Self.defaultModel,
                "messages": [["role": "system", "content": request.instructions], ["role": "user", "content": request.input]],
            ]
            let model = request.model ?? Self.defaultModel
            if model.hasPrefix("qwen/") {
                body["reasoning_format"] = "hidden"
                if request.effort == .fast { body["reasoning_effort"] = "none" }
            } else if model.hasPrefix("openai/gpt-oss-"), request.effort == .fast {
                body["reasoning_effort"] = "low"
            }
            if let schema = request.schema {
                guard let object = try? JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any] else {
                    throw AIError.invalidOutput("Invalid response schema.")
                }
                body["response_format"] = object["type"] as? String == "object" && Self.isStrictSchema(object)
                    ? ["type": "json_schema", "json_schema": ["name": "tern_response", "strict": true, "schema": object]]
                    : ["type": "json_object"]
            }
            if request.schema != nil {
                body["messages"] = [["role": "system", "content": request.instructions + "\nReturn JSON."], ["role": "user", "content": request.input]]
            }
            for attempt in 0...1 {
                http.httpBody = try JSONSerialization.data(withJSONObject: body)
                let data: Data
                let response: URLResponse
                do {
                    (data, response) = try await session.data(for: http)
                } catch let error as URLError {
                    if error.code == .timedOut { throw AIError.timedOut }
                    if error.code == .cancelled { throw CancellationError() }
                    throw AIError.failed("Groq couldn't be reached.")
                } catch is CancellationError { throw CancellationError() }
                catch { throw AIError.failed("Groq couldn't be reached.") }
                guard let response = response as? HTTPURLResponse else { throw AIError.failed("Groq returned an invalid response.") }
                if response.statusCode == 400, attempt == 0, request.schema != nil,
                   let error = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any],
                   let message = error["message"] as? String,
                   message.lowercased().contains("response_format") || message.lowercased().contains("schema") {
                    body["response_format"] = ["type": "json_object"]
                    continue
                }
                switch response.statusCode {
                case 200..<300: break
                case 401, 403: throw AIError.notSignedIn(provider: displayName)
                case 429:
                    let retry = response.value(forHTTPHeaderField: "Retry-After")
                    throw AIError.rateLimited("Groq's rate limit was reached." + (retry.map { " Retry after \($0)." } ?? " Try again later."))
                default: throw AIError.failed("Groq request failed (HTTP \(response.statusCode)).")
                }
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = object["choices"] as? [[String: Any]],
                      let message = choices.first?["message"] as? [String: Any], let content = message["content"] as? String else {
                    throw AIError.invalidOutput("Groq returned no answer.")
                }
                let clean = content.replacingOccurrences(of: "(?is)<think>.*?</think>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "(?is)^\\s*<think>.*$", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !clean.isEmpty else { throw AIError.invalidOutput("Groq returned no answer.") }
                return clean
            }
            throw AIError.failed("Groq request failed after retry.")
        }
    }

    /// Strict output requires every object property, including objects nested in arrays, to be required.
    static func isStrictSchema(_ schema: [String: Any]) -> Bool {
        if schema["type"] as? String == "object" || schema["properties"] != nil {
            guard let properties = schema["properties"] as? [String: Any],
                  schema["additionalProperties"] as? Bool == false,
                  let required = schema["required"] as? [String], Set(required) == Set(properties.keys) else { return false }
        }
        for value in schema.values {
            if let child = value as? [String: Any], !isStrictSchema(child) { return false }
            if let children = value as? [[String: Any]], !children.allSatisfy({ isStrictSchema($0) }) { return false }
        }
        return true
    }
}
