import Foundation
import os

/// Model access through a signed-in local CLI or an HTTP provider with an app-supplied API key.
public protocol AIProvider: Sendable {
    /// Stored in `ThreadAI.source` and the `ai.provider` setting: "groq", "codex" or "claude".
    var id: String { get }
    var displayName: String { get }
    /// Ready to make calls? CLI checks are cached; HTTP providers check for a credential.
    func availability(refresh: Bool) async -> AIAvailability
    /// Models the user can pick in settings. The first is the fast default.
    func models() async -> [String]
    /// Runs one request and returns the model's final answer (JSON text when `schema` is set).
    func complete(_ request: AIRequest) async throws -> String
}

extension AIProvider {
    /// True when this backend is ready to make calls.
    public func isAvailable() async -> Bool {
        await availability(refresh: false) == .ready
    }

    /// Runs one free-text prompt with no extra instructions.
    public func complete(_ prompt: String) async throws -> String {
        try await complete(AIRequest(instructions: "", input: prompt))
    }
}

public enum AIAvailability: Hashable, Sendable {
    case ready
    case notInstalled
    case signedOut
}

/// One model call. `instructions` may travel on the command line, so it must never contain mail;
/// `input` holds mail data, sent on stdin for CLIs or in the HTTPS body for HTTP providers.
public struct AIRequest: Hashable, Sendable {
    public enum Effort: String, Hashable, Sendable {
        /// Classification and short answers.
        case fast
        /// Writing (reply drafts).
        case careful
    }

    public var instructions: String
    public var input: String
    /// JSON Schema (as JSON text) the answer must follow. Root must be an object.
    public var schema: String?
    /// Model id or alias; nil uses the provider's fast default.
    public var model: String?
    public var effort: Effort
    /// Seconds before a request times out.
    public var timeout: TimeInterval
    /// Work nobody is waiting on (triage): it queues behind on-demand calls for a CLI slot and the CLI
    /// runs at a lower scheduling priority.
    public var isBackground: Bool

    public init(
        instructions: String, input: String, schema: String? = nil, model: String? = nil,
        effort: Effort = .fast, timeout: TimeInterval = 120, isBackground: Bool = false
    ) {
        self.instructions = instructions
        self.input = input
        self.schema = schema
        self.model = model
        self.effort = effort
        self.timeout = timeout
        self.isBackground = isBackground
    }
}

public enum AIError: Error, Hashable, Sendable, LocalizedError {
    /// AI is turned off in settings.
    case disabled
    case notInstalled(provider: String)
    case notSignedIn(provider: String)
    /// Usage or rate limit reached; try again later.
    case rateLimited(String)
    case timedOut
    /// The provider failed. The message never contains mail content.
    case failed(String)
    /// The answer wasn't usable even after one retry.
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .disabled: "AI is turned off in settings."
        case .notInstalled(let provider): "\(provider) isn't installed."
        case .notSignedIn(let provider): "\(provider) isn't signed in."
        case .rateLimited(let message): message.isEmpty ? "The AI usage limit was reached. Try again later." : message
        case .timedOut: "The AI took too long to answer."
        case .failed(let message): message
        case .invalidOutput: "The AI answer couldn't be read."
        }
    }
}

let aiLog = Logger(subsystem: "dev.tern.mail", category: "ai")
