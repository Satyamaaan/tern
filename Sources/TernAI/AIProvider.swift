import Foundation

/// A local AI backend driven through a CLI the user already signs in to (Codex or Claude Code).
/// The AI lane replaces this placeholder with the real providers and the classifier.
public protocol AIProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    /// True when the CLI is installed and signed in.
    func isAvailable() async -> Bool
    /// Runs one prompt and returns the model's text answer.
    func complete(_ prompt: String) async throws -> String
}
