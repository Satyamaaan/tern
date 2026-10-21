import Foundation
import Observation
import TernAI

/// Whether a provider's CLI can run right now: TernAI's `availability(refresh:)` as the app shows it.
enum AIStatus: Hashable, Sendable {
    case ready
    case signedOut
    case notInstalled

    init(_ availability: AIAvailability) {
        switch availability {
        case .ready: self = .ready
        case .signedOut: self = .signedOut
        case .notInstalled: self = .notInstalled
        }
    }
}

/// Checks one provider's CLI; `refresh` skips TernAI's cached answer. Runs off the main thread.
typealias AIAvailabilityCheck = @Sendable (AIProvider, _ refresh: Bool) async -> AIStatus

extension AIProvider {
    /// The providers backed by a CLI, in the order the choices show them.
    static let tools: [AIProvider] = [.groq, .claude, .codex]

    var logo: BrandLogo? {
        switch self {
        case .claude: .claude
        case .codex: .openAI
        case .automatic, .groq, .off: nil
        }
    }

    /// What pays for the calls, in one plain line.
    var tagline: String {
        switch self {
        case .claude: "Uses your Claude subscription"
        case .codex: "Uses your ChatGPT plan"
        case .automatic: "Groq with a key, then a ready CLI"
        case .groq: "Uses your Groq API key"
        case .off: "No AI features"
        }
    }

    /// What to run in Terminal to sign in. Claude Code reports a sign-out only in versions with `auth`.
    var signInCommand: String? {
        switch self {
        case .claude: "claude auth login"
        case .codex: "codex login"
        case .automatic, .groq, .off: nil
        }
    }

    /// The official install instructions.
    var installURL: URL? {
        switch self {
        case .claude: URL(string: "https://code.claude.com/docs/en/setup")
        case .codex: URL(string: "https://developers.openai.com/codex/cli")
        case .automatic, .groq, .off: nil
        }
    }
}

/// The providers' live status. Checks run off the main thread and land here; nothing waits on them.
@MainActor
@Observable
final class AIStatusBoard {
    private(set) var statuses: [AIProvider: AIStatus] = [:]
    private(set) var isChecking = false

    /// Asks every provider at once. Does nothing while a check runs, or without a checker (snapshots
    /// and `--check` pass a fake one or none, so the real CLIs never run there).
    func check(_ availability: AIAvailabilityCheck?, refresh: Bool = false) {
        guard let availability, !isChecking else { return }
        isChecking = true
        Task {
            let results = await withTaskGroup(of: (AIProvider, AIStatus).self) { group in
                for provider in AIProvider.tools {
                    group.addTask { (provider, await availability(provider, refresh)) }
                }
                return await group.reduce(into: [AIProvider: AIStatus]()) { $0[$1.0] = $1.1 }
            }
            statuses = results
            isChecking = false
        }
    }

    /// The first provider that's ready, Claude Code before Codex.
    var firstReady: AIProvider? {
        AIProvider.tools.first { statuses[$0] == .ready }
    }

    /// True once a check has answered and something isn't ready.
    var needsAttention: Bool {
        AIProvider.tools.contains { statuses[$0].map { $0 != .ready } ?? false }
    }
}
