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
    /// Discards one draft of a conversation (the reader's Discard), with the shell's undo toast.
    var discardDraft: (MessageKey, ThreadKey) -> Void = { _, _ in }
    /// Opens the composer (new window or inline, decided by the request).
    var compose: (ComposeRequest) -> Void = { _ in }
    /// Opens a Gmail draft stored as a DRAFT message in a composer window, fetching its body first
    /// when only its headers are stored.
    var openDraftMessage: (MessageKey) -> Void = { _ in }
    /// Downloads an attachment (or inline image) to a local file. Wired to the sync engine.
    var loadAttachment: (MailAttachment) async throws -> URL = { _ in throw CocoaError(.featureUnsupported) }
    /// AI helpers; nil when AI is off or unavailable.
    var ai: AIActions?
    /// What AI sorting is doing, for Settings → AI. Set by the integration; nil until it starts.
    var aiSorting: AISorting?
    /// Tells AI sorting which threads are on screen (the rows in view and the open thread), so they are
    /// sorted before the rest. Each call replaces the last.
    var aiPrioritize: (([ThreadKey]) -> Void)?
    /// Checks whether Claude Code or Codex is installed and signed in, for onboarding and Settings → AI.
    /// Wired to TernAI's providers by the integration; nil leaves the status unknown (snapshots inject
    /// their own).
    var aiAvailability: AIAvailabilityCheck?
    /// Where drafts keep pasted images and attached copies. Nil uses Application Support/Tern/Draft Files.
    var draftFilesDirectory: URL?
    /// Shows the "Sending in 5 s · Undo" notice after Send. When nil the composer shows its own floating pill.
    var showSendUndo: ((SendUndoNotice) -> Void)?
    /// Archives a thread after "Send and archive", without a toast of its own: the shell takes the row
    /// out of the list at once and selects the next one. Returns what undoing the send needs. When nil
    /// the composer archives through the store directly.
    var archiveSent: ((ThreadKey) async -> UndoToken?)?

    /// Drafts and their Gmail operations (compose lane).
    var drafts: DraftStore { DraftStore(store.database, filesDirectory: draftFilesDirectory) }

    // MARK: Shell hooks (the shell provides no-op defaults; integration wires the real ones)

    /// Runs Google sign-in for a new account and returns it once stored. Wired to the Google lane.
    var connectAccount: () async throws -> Account? = { throw ShellError.notAvailable }
    /// Signs an existing account in again after its token stopped working.
    var reauthAccount: (Account) async throws -> Void = { _ in throw ShellError.notAvailable }
    /// Runs Google sign-in for a new account through one of the stored clients (nil: the default one).
    var connectAccountWith: (_ clientId: String?) async throws -> Account? = { _ in throw ShellError.notAvailable }
    /// Stores one of the user's own Google OAuth clients (onboarding step 1, Settings) in the Keychain. A
    /// client already stored under the same ID gets the new secret.
    var saveGoogleClient: (_ clientId: String, _ clientSecret: String) async throws -> Void = { _, _ in
        throw ShellError.notAvailable
    }
    /// Whether a Google OAuth client is stored.
    var hasGoogleClient: () -> Bool = { false }
    /// The stored client's ID, for Settings to show masked.
    var googleClientId: () -> String? = { nil }
    /// Stores the client from the JSON file Google offers when it is created (`client_secret_….json`).
    var importGoogleClient: (Data) async throws -> Void = { _ in throw ShellError.notAvailable }
    /// Every stored client, the default first, with the accounts that sign in through each.
    var googleClients: () -> [GoogleClientInfo] = { [] }
    /// The client saved last in this session, so onboarding signs in through the one just entered even when
    /// an earlier one is the default.
    var lastSavedGoogleClientId: String?
    /// Goes up each time a client is added, updated or removed, so views showing `googleClients` reload.
    var googleClientsChanged = 0
    /// Removes a stored client. Accounts that signed in through it have to sign in again.
    var removeGoogleClient: (_ clientId: String) async throws -> Void = { _ in throw ShellError.notAvailable }
    /// Live sync progress, set by the sync engine. Nil shows the state stored on the accounts.
    var syncProgress: SyncProgress?
    /// What the sidebar's sync line says, from the sync engine's live status. Nil falls back to
    /// `syncProgress` and the state stored on the accounts.
    var syncLine: SyncLine?
    /// Removes an account: stops its sync, deletes its mail from this Mac and signs it out of Google.
    var removeAccount: (Account) async throws -> Void
    /// True while the network is unreachable.
    var isOffline = false
    /// Set while an editor outside AppKit text views (e.g. a web-based rich text body) has focus, so
    /// bare-key shortcuts stay off.
    var isComposing = false
    /// Called after a project or its rules change, so rules can be applied to existing mail.
    var projectRulesChanged: (String) -> Void = { _ in }
    /// Brings a thread to the front (notifications, mailto links). Set by the shell.
    var showThread: (ThreadKey) -> Void = { _ in }

    /// Reader actions for the shell's key handling and the ⌘K palette (next/previous message, find, print…).
    let reader = ReaderCommands()
    /// Text a ✦ quick reply chose for a thread's next reply. The composer reads it and clears it.
    var replyPrefill: [ThreadKey: String] = [:]
    /// Mutes threads (archive now, keep later replies out of the inbox). Nil until sync supports it;
    /// the reader's Mute item is disabled meanwhile.
    var mute: (([ThreadKey]) -> Void)?
    /// Mutes threads through sync (archive + Tern's "Muted" label; later replies stay archived): a
    /// local write, called on the model's serial write queue like every other action. Returns the
    /// undo token. Nil until sync runs; `m` then just archives.
    var muteThreads: (@Sendable ([ThreadKey]) throws -> UndoToken)?
    /// Downloads the bodies of a thread's messages stored without one. Set by sync; the reader calls
    /// it when a thread opens and re-renders when they land.
    var fetchBodies: ((ThreadKey) async throws -> Void)?
    /// Asks sync for the bodies of the threads around the selection, when quota allows.
    var prefetchBodies: (([ThreadKey]) -> Void)?
    /// Searches Gmail for older mail matching the search text and stores what it finds; returns how many
    /// threads Gmail matched. Nil until sync can search; the results then end with
    /// "Search older mail on Gmail".
    var serverSearch: ((String) async throws -> Int)?

    init(store: MailStore) {
        self.store = store
        self.search = SearchService(store.database)
        removeAccount = { account in
            _ = try await Task.detached { try store.removeAccount(account.id) }.value
        }
    }

    func account(_ id: String) -> Account? { accounts.first { $0.id == id } }
}

/// A stored Google OAuth client and the accounts (lowercased emails) that sign in through it.
struct GoogleClientInfo: Hashable, Identifiable {
    let id: String
    var emails: [String]
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
    /// Writes a new message (not a reply) from an instruction that includes recipients and subject.
    /// Returns plain text or simple HTML. Nil hides ✦ Write with AI for new mail.
    var writeDraft: ((String) async throws -> String)? = nil
}

/// What the composer reports after Send or Send later, for the shell's toast area.
struct SendUndoNotice {
    let draftId: String
    /// "Sending" or "Scheduled for Tue 8:00".
    let message: String
    /// End of the undo window for a countdown ("Sending in 4 s"); nil for scheduled sends.
    let deadline: Date?
    /// How long to keep the notice up.
    let duration: TimeInterval
    /// Cancels the send (and a send-and-archive) and reopens the draft.
    let undo: @MainActor () -> Void
}

/// Sync progress reported by the sync engine, shown in the sidebar's status line.
struct SyncProgress: Hashable {
    var done: Int
    var total: Int
}

/// The sidebar's one line of sync status.
struct SyncLine: Hashable {
    enum Tone: Hashable {
        /// Work in the background, or waiting on Gmail: a quiet dot.
        case quiet
        /// The first sync of an account, which the user is waiting on.
        case working
        /// Something the user should know about (changes Gmail refused).
        case attention
    }

    var text: String
    var tone: Tone
    /// The longer form, shown on hover.
    var detail: String?
    /// Where clicking the line goes, e.g. the Google Cloud page that turns the Gmail API on.
    var url: URL?
}

enum ShellError: LocalizedError {
    case notAvailable

    var errorDescription: String? {
        switch self {
        case .notAvailable: "Not available yet"
        }
    }
}
