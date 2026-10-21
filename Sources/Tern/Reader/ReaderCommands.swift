import Foundation
import TernCore

/// Reader actions the shell can trigger from its own key handling or the ⌘K palette, for whichever
/// reader is showing a thread. Inside the reader's web view the keys of Next and Previous Message, Open and
/// Quick Look work directly (`KeyRouter.pageKeyMap`).
@MainActor
final class ReaderCommands {
    weak var model: ReaderModel?

    /// True when a conversation is open.
    var isActive: Bool { model?.key != nil }

    /// True when the reader shows `key`. A reader off screen keeps the last thread it showed while the
    /// selection moves on, so commands for the selected thread check this first.
    func shows(_ key: ThreadKey?) -> Bool { key != nil && model?.key == key }

    func nextMessage() { model?.nextMessage() }
    func previousMessage() { model?.previousMessage() }
    /// Expands or collapses the focused message.
    func toggleMessage() { model?.toggleMessage() }
    func find() { model?.openFind() }
    func findNext() { model?.findAgain(backwards: false) }
    func findPrevious() { model?.findAgain(backwards: true) }
    /// Moves keyboard focus into the conversation.
    func focus() { model?.focusPage() }
    func printThread() { model?.printThread() }
    func reply(all: Bool = false) { model?.reply(all: all) }
    func forward() { model?.forward() }
    func summarize() { model?.summaryClicked() }
    func showOriginal() { model?.showOriginal() }
    /// Quick Look for the selected attachment.
    func quickLook() { model?.quickLookSelectedAttachment() }
}
