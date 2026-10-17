import AppKit
import TernCore

// Inline images in the body are files the draft carries, referenced as `cid:` and sent with the
// message as `multipart/related`. Files still only in the original message (a Gmail draft opened
// here) are fetched to be shown; the engine fetches them again for sending.
extension ComposerModel {
    /// The picture for an inline image's `src`, once its file is on this Mac.
    func inlineImage(_ source: String) -> NSImage? {
        guard let file = inlineFile(source) else { return nil }
        if !file.path.isEmpty { return NSImage(contentsOfFile: file.path) }
        return fetchedImages[source]
    }

    /// Fetches the files of `body`'s inline images that are still in Gmail, then redraws them.
    func fetchInlineImages(in body: RichText) {
        let sources = Set(body.blocks.flatMap(\.runs).compactMap(\.image))
        for source in sources {
            guard let file = inlineFile(source), file.needsFetch, let ref = file.remote else { continue }
            let attachment = MailAttachment(
                accountId: ref.accountId, messageId: ref.messageId, partId: ref.partId, attachmentId: ref.attachmentId,
                filename: file.filename, mimeType: file.mimeType, size: file.size, contentId: file.contentId, isInline: true)
            let load = services.loadAttachment
            Task { [weak self] in
                guard let url = try? await load(attachment), let image = NSImage(contentsOf: url), let self else { return }
                fetchedImages[source] = image
                editor.reloadImages()
            }
        }
    }

    private func inlineFile(_ source: String) -> DraftAttachment? {
        guard source.lowercased().hasPrefix("cid:") else { return nil }
        let contentId = String(source.dropFirst(4))
        return attachments.first { $0.contentId == contentId }
    }
}
