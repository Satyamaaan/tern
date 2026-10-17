import Foundation
import GRDB
import TernCore

// Gmail settings the composer uses: the default signature and the name mail goes out with.
extension AccountSync {
    /// Reads the account's send-as identities (1 unit). The default identity's HTML signature goes
    /// to `setting` `signature.<accountId>` unless the user set one in Tern
    /// (`signature.<accountId>.custom` = 1); the account address's display name goes to
    /// `sender.name.<accountId>` for `DraftEncoder`.
    public func refreshSendAs() async throws {
        let identities = try await withRetry { [api] in try await api.sendAs() }
        let own = identities.first { $0.sendAsEmail.caseInsensitiveCompare(account.email) == .orderedSame }
            ?? identities.first { $0.isPrimary == true }
        let signature = (identities.first { $0.isDefault == true } ?? own)?.signature?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name = own?.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountId = self.accountId
        try await write { db in
            if try Setting.fetchOne(db, key: DraftStore.SettingKey.customSignature(accountId))?.value != "1" {
                try AccountSync.setSetting(db, DraftStore.SettingKey.signature(accountId), signature)
            }
            try AccountSync.setSetting(db, DraftStore.SettingKey.senderName(accountId), name)
        }
        nextSendAsRefreshAt = clock.now().addingTimeInterval(configuration.dailyInterval)
    }

    /// `refreshSendAs` from the loop. Signing in again and rate limits concern the whole account;
    /// any other failure leaves the settings as they are and tries again in an hour.
    func refreshSendAsIfPossible(now: Date) async throws {
        do {
            try await refreshSendAs()
        } catch GmailAPIError.unauthorized {
            throw GmailAPIError.unauthorized
        } catch GmailAPIError.rateLimited(let retryAfter) {
            throw GmailAPIError.rateLimited(retryAfter: retryAfter)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            nextSendAsRefreshAt = now.addingTimeInterval(min(3600, configuration.dailyInterval))
        }
    }

    static func setSetting(_ db: Database, _ key: String, _ value: String?) throws {
        if let value, !value.isEmpty {
            try Setting(key: key, value: value).upsert(db)
        } else {
            _ = try Setting.deleteOne(db, key: key)
        }
    }
}
