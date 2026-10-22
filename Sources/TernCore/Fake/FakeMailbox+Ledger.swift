import Foundation
import GRDB

extension FakeMailbox {
    /// Expected results for synthetic rule evaluation. These threads never overlap the normal seed.
    public struct LedgerGold: Sendable {
        public var key: ThreadKey
        public var waiting: Bool
    }

    /// Adds reproducible positives and hard negatives without consuming the normal seed's RNG.
    public static func populateLedgerGold(_ database: AppDatabase, count: Int, seed: UInt64 = 7, now: Date = Date()) throws -> [LedgerGold] {
        var gold: [LedgerGold] = []
        var messages: [MailMessage] = []
        var rng = SplitMix64(state: seed)
        for index in 0..<max(0, count) {
            let variant = index % 8
            let account = accounts[index % accounts.count]
            let key = ThreadKey(accountId: account.id, threadId: "ledger-gold-\(index)")
            let date = now.addingTimeInterval(-Double(4 + rng.next() % 12) * 86_400)
            let recipient = Participant(name: "Maya Chen", email: variant == 2 ? "noreply@example.com" : "maya@example.com")
            var ask = MailMessage(accountId: account.id, id: key.threadId + "-ask", threadId: key.threadId, date: date,
                fromEmail: account.email, toList: [recipient], subject: "Review the launch proposal \(index)",
                snippet: "Could you review the launch proposal and send your thoughts?", labelIds: [SystemLabel.sent], isFromMe: true)
            switch variant {
            case 1: ask.snippet = "Thanks, sounds good!"
            case 3: ask.listUnsubscribe = "<mailto:unsubscribe@example.com>"
            case 6: ask.toList = [Participant(email: accounts[(index + 1) % accounts.count].email)]
            case 7: ask.toList = (0..<7).map { Participant(email: "person\($0)@example.com") }
            default: break
            }
            messages.append(ask)
            if variant == 4 || variant == 5 {
                messages.append(MailMessage(accountId: account.id, id: key.threadId + "-reply", threadId: key.threadId,
                    date: date.addingTimeInterval(86_400), fromName: "Maya Chen", fromEmail: recipient.email,
                    toList: [Participant(email: account.email)], subject: variant == 4 ? "Automatic reply: Out of office" : ask.subject,
                    snippet: variant == 4 ? "I'm away this week." : "Here are my thoughts.", labelIds: [SystemLabel.inbox]))
            }
            gold.append(LedgerGold(key: key, waiting: variant == 0 || variant == 4))
        }
        try database.writer.write { db in
            for account in accounts { try account.upsert(db) }
            let keys = try MailStore.upsertMessages(db, messages)
            try MailStore.applyRules(db, keys: keys, now: now)
        }
        return gold
    }
}
