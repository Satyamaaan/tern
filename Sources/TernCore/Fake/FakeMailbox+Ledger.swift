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
        var replies: [MailMessage] = []
        var rng = SplitMix64(state: seed)
        for index in 0..<max(0, count) {
            let variant = index % 16
            let account = accounts[index % accounts.count]
            let key = ThreadKey(accountId: account.id, threadId: "ledger-gold-\(index)")
            let date = now.addingTimeInterval(-Double(4 + rng.next() % 12) * 86_400)
            let recipient = Participant(name: "Maya Chen", email: variant == 2 ? "noreply@example.com" : "maya@example.com")
            var ask = MailMessage(accountId: account.id, id: key.threadId + "-ask", threadId: key.threadId, date: date,
                fromEmail: account.email, toList: [recipient], subject: "Review the launch proposal \(index)",
                snippet: "Could you review the launch proposal and send your thoughts?", labelIds: [SystemLabel.sent], isFromMe: true)
            switch variant {
            case 8: ask.snippet = "Please share the final schedule"
            case 9: ask.snippet = "Can you confirm the shipping date"
            case 10: ask.snippet = "Would you sign the revised agreement"
            case 11: ask.snippet = "Here is https://example.com/proposal?view=latest"
            case 12: ask.snippet = "Please find attached the receipt."
            case 13: ask.snippet = "I confirm receipt of your proposal."
            case 14: ask.snippet = "Looking forward to our meeting."
            case 15: ask.snippet = "I approve the changes."
            case 1: ask.snippet = "Thanks, sounds good!"
            case 3: ask.listUnsubscribe = "<mailto:unsubscribe@example.com>"
            case 6: ask.toList = [Participant(email: accounts[(index + 1) % accounts.count].email)]
            case 7: ask.toList = (0..<7).map { Participant(email: "person\($0)@example.com") }
            default: break
            }
            messages.append(ask)
            if variant == 4 || variant == 5 {
                replies.append(MailMessage(accountId: account.id, id: key.threadId + "-reply", threadId: key.threadId,
                    date: date.addingTimeInterval(86_400), fromName: "Maya Chen", fromEmail: recipient.email,
                    toList: [Participant(email: account.email)], subject: variant == 4 ? "Automatic reply: Out of office" : ask.subject,
                    snippet: variant == 4 ? "I'm away this week." : "Here are my thoughts.", labelIds: [SystemLabel.inbox]))
            }
            gold.append(LedgerGold(key: key, waiting: [0, 4, 8, 9, 10].contains(variant)))
        }
        try database.writer.write { db in
            for account in accounts { try account.upsert(db) }
            let keys = try MailStore.upsertMessages(db, messages)
            try MailStore.applyRules(db, keys: keys, now: now)
            // Replay the timeline: requests arrive first, then human and automatic replies.
            let replyKeys = try MailStore.upsertMessages(db, replies)
            try MailStore.applyRules(db, keys: replyKeys, now: now)
        }
        return gold
    }
}
