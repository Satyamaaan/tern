import Foundation
import Observation
import TernCore

/// What every screen needs, created once by the app shell and passed through the SwiftUI environment
/// (`@Environment(AppServices.self)`). Lanes may add members; don't remove or rename existing ones.
@MainActor
@Observable
final class AppServices {
    let store: MailStore
    let search: SearchService
    /// Connected accounts, kept current by the shell.
    var accounts: [Account] = []
    var projects: [Project] = []

    /// Runs a mail action with the shell's undo toast and selection handling.
    var perform: (MailAction, [ThreadKey]) -> Void = { _, _ in }
    /// Opens the composer (new window or inline, decided by the request).
    var compose: (ComposeRequest) -> Void = { _ in }
    /// Downloads an attachment (or inline image) to a local file. Wired to the sync engine.
    var loadAttachment: (MailAttachment) async throws -> URL = { _ in throw CocoaError(.featureUnsupported) }
    /// AI helpers; nil when AI is off or unavailable.
    var ai: AIActions?

    // MARK: Shell hooks (the shell provides no-op defaults; integration wires the real ones)

    /// Runs Google sign-in for a new account and returns it once stored. Wired to the Google lane.
    var connectAccount: () async throws -> Account? = { throw ShellError.notAvailable }
    /// Signs an existing account in again after its token stopped working.
    var reauthAccount: (Account) async throws -> Void = { _ in throw ShellError.notAvailable }
    /// Stores the user's own Google OAuth client (onboarding step 1) in the Keychain.
    var saveGoogleClient: (_ clientId: String, _ clientSecret: String) async throws -> Void = { _, _ in
        throw ShellError.notAvailable
    }
    /// Whether a Google OAuth client is stored.
    var hasGoogleClient: () -> Bool = { false }
    /// Live sync progress, set by the sync engine. Nil shows the state stored on the accounts.
    var syncProgress: SyncProgress?
    /// True while the network is unreachable.
    var isOffline = false
    /// Set while an editor outside AppKit text views (e.g. a web-based rich text body) has focus, so
    /// bare-key shortcuts stay off.
    var isComposing = false
    /// Called after a project or its rules change, so rules can be applied to existing mail.
    var projectRulesChanged: (String) -> Void = { _ in }
    /// Brings a thread to the front (notifications, mailto links). Set by the shell.
    var showThread: (ThreadKey) -> Void = { _ in }

    init(store: MailStore) {
        self.store = store
        self.search = SearchService(store.database)
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
}

/// What the composer should open.
enum ComposeRequest: Hashable {
    case new(accountId: String?, to: [Participant] = [])
    case reply(ThreadKey, all: Bool)
    case forward(ThreadKey)
    /// Reopen an existing local draft.
    case draft(id: String)
}

/// On-demand AI features, backed by TernAI.
struct AIActions {
    var summarize: (ThreadKey) async throws -> [String]
    var suggestReplies: (ThreadKey) async throws -> [String]
    var draftReply: (ThreadKey, String) async throws -> String
    var naturalLanguageQuery: (String) async throws -> String
}

/// Sync progress reported by the sync engine, shown in the sidebar's status line.
struct SyncProgress: Hashable {
    var done: Int
    var total: Int
}

enum ShellError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Not available yet"
        }
    }
}
