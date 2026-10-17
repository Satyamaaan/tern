import Foundation
import GRDB
import TernCore

public enum SyncError: Error, Sendable, Equatable {
    /// No sync is running for this account.
    case unknownAccount(String)
    /// The attachment's data couldn't be found in the message.
    case attachmentUnavailable
}

// Attachments and server search.
extension AccountSync {
    /// Returns a local file for the attachment, downloading it on first use into
    /// `<cache>/<account>/<message>/<filename>` and saving the path on the record.
    /// Used for inline `cid:` images and Quick Look.
    public func downloadAttachment(_ attachment: MailAttachment) async throws -> URL {
        let accountId = self.accountId
        let current = try await read { db in
            try MailAttachment.fetchOne(db, key: ["accountId": accountId, "messageId": attachment.messageId, "partId": attachment.partId])
        } ?? attachment
        if let path = current.localPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }

        let data = try await attachmentData(current)
        let url = try await cacheURL(for: current)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let path = url.path
        try await write { db in try MailStore.setAttachmentPath(db, current, path: path) }
        return url
    }

    private func attachmentData(_ attachment: MailAttachment) async throws -> Data {
        if let attachmentId = attachment.attachmentId {
            do {
                return try await withRetry { [api] in try await api.attachment(messageId: attachment.messageId, attachmentId: attachmentId) }
            } catch GmailAPIError.notFound {
                // Gmail attachment ids can go stale; look the part up again below.
            }
        }
        let messages = try await withRetry { [api] in try await api.messages(ids: [attachment.messageId], format: .full) }
        guard let part = messages.first?.payload.flatMap({ AccountSync.findPart(attachment.partId, in: $0) }) else {
            throw SyncError.attachmentUnavailable
        }
        if let data = part.body?.data.flatMap(MailParsing.base64URLDecode) { return data }
        if let freshId = part.body?.attachmentId {
            return try await withRetry { [api] in try await api.attachment(messageId: attachment.messageId, attachmentId: freshId) }
        }
        throw SyncError.attachmentUnavailable
    }

    static func findPart(_ partId: String, in part: GmailMessagePart) -> GmailMessagePart? {
        let id = (part.partId ?? "").isEmpty ? "0" : part.partId!
        if id == partId { return part }
        for child in part.parts ?? [] {
            if let found = findPart(partId, in: child) { return found }
        }
        return nil
    }

    /// The cache path. Two attachments of one message with the same name get the part id appended.
    private func cacheURL(for attachment: MailAttachment) async throws -> URL {
        let accountId = self.accountId
        let clashes = try await read { db in
            try MailAttachment
                .filter(Column("accountId") == accountId && Column("messageId") == attachment.messageId
                    && Column("filename") == attachment.filename && Column("partId") != attachment.partId)
                .fetchCount(db)
        }
        var name = AccountSync.safeFilename(attachment.filename, fallback: "attachment-\(attachment.partId)")
        if clashes > 0 {
            let base = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            name = ext.isEmpty ? "\(base) (\(attachment.partId))" : "\(base) (\(attachment.partId)).\(ext)"
        }
        return configuration.attachmentCacheDirectory
            .appendingPathComponent(AccountSync.safeFilename(accountId, fallback: "account"), isDirectory: true)
            .appendingPathComponent(AccountSync.safeFilename(attachment.messageId, fallback: "message"), isDirectory: true)
            .appendingPathComponent(name)
    }

    static func safeFilename(_ name: String, fallback: String) -> String {
        let cleaned = name.map { $0 == "/" || $0 == ":" || $0 == "\0" ? "-" : $0 }
        let result = String(cleaned).trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty || result == "." || result == ".." ? fallback : String(result.prefix(200))
    }

    /// Searches Gmail itself (for mail older than the local backfill), stores any messages not
    /// stored yet, and returns the matching threads, best match first.
    public func serverSearch(query: String, limit: Int) async throws -> [ThreadKey] {
        let page = try await withRetry { [api] in
            try await api.messageIds(query: query, labelIds: [], pageToken: nil, maxResults: max(1, min(limit, 500)))
        }
        let refs = page.messages ?? []
        let accountId = self.accountId
        let ids = refs.map(\.id)
        let stored = try await read { db in try MailStore.storedMessageIds(db, accountId: accountId, among: ids) }
        let missing = try await fetchAndStore(ids.filter { !stored.contains($0) }, format: .full)
        let gone = Set(missing)
        var seen = Set<String>()
        return refs.compactMap { ref in
            guard !gone.contains(ref.id), seen.insert(ref.threadId).inserted else { return nil }
            return ThreadKey(accountId: accountId, threadId: ref.threadId)
        }
    }
}
