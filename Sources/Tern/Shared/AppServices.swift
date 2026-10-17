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
    /// Where drafts keep pasted images and attached copies. Nil uses Application Support/Tern/Draft Files.
    var draftFilesDirectory: URL?
    /// Shows the "Sending in 5 s · Undo" notice after Send. When nil the composer shows its own floating pill.
    var showSendUndo: ((SendUndoNotice) -> Void)?

    /// Drafts and their Gmail operations (compose lane).
    var drafts: DraftStore { DraftStore(store.database, filesDirectory: draftFilesDirectory) }

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
