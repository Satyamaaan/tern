import Foundation
import GRDB

extension FakeMailbox {
    /// Gold labels for extraction, independent of the normal fake mailbox random stream.
    public struct LedgerAIGold: Codable, Sendable {
        public var thread: ThreadKey
        public var direction: LedgerDirection?
        public var counterparty: String
        public var deliverableKeywords: [String]
        public var deliverableAlternatives: [[String]]? = nil
        public var sourceAlternatives: [Int]? = nil
        public var due: String?
        public var sourceIndex: Int
        public var finalState: String
    }

    /// Appends a balanced set of explicit commitments and hard negatives. Zero leaves the database alone.
    public static func populateLedgerAIGold(_ database: AppDatabase, count: Int, now: Date = Date()) throws -> [LedgerAIGold] {
        guard count > 0 else { return [] }
        let positive: [(String, Bool, LedgerDirection, [String])] = [
            ("I'll send the revised deck.pptx by Thursday.", true, .iOwe, ["deck"]),
            ("Can you send the W-9.pdf by Friday?", false, .iOwe, ["w", "9"]),
            ("Could you share the signed contract by tomorrow?", true, .waitingOn, ["contract"]),
            ("I'll get you the numbers Monday.", false, .waitingOn, ["numbers"]),
            ("I will review the security questionnaire and send my answers tomorrow.", true, .iOwe, ["questionnaire"]),
            ("Please review the draft budget and send me your decision by EOD.", false, .iOwe, ["budget"]),
            ("Please send the final schedule by Friday.", true, .waitingOn, ["schedule"]),
            ("I will send you the invoice tomorrow.", false, .waitingOn, ["invoice"]),
            ("I'll get back to you with the deployment decision by Tuesday.", true, .iOwe, ["decision"]),
            ("Could you sign the revised agreement by Wednesday?", false, .iOwe, ["agreement"]),
            ("Can you send me the audit report by Monday?", true, .waitingOn, ["report"]),
            ("I'll share the updated Node.js plan and roadmap by Friday.", false, .waitingOn, ["node", "js", "plan"]),
        ]
        let negative = [
            "We should send a deck sometime, if the project goes ahead.",
            "Thanks, that sounds good!",
            "Maya said she'll send Noah the budget by Friday.",
            "We'll send you updates about our products. Subscribe for more news.",
            "We'll notify you when your automated export is ready.",
            "Thanks!\n\nOn Monday Maya wrote:\n> I'll send the revised deck.pptx by Thursday.",
            "If we win, I will send a proposal. For now this is hypothetical.",
            "Can you believe how quickly the week went?",
            "We should follow up on this idea someday.",
            "Please review our newsletter: a roundup of the best tools this week.",
            "I'll be away next week. Have a lovely weekend!",
            "The deadline for the conference was last month. Nothing to do now.",
        ]
        var messages: [MailMessage] = []
        var gold: [LedgerAIGold] = []
        for index in 0..<count {
            let account = accounts[index % accounts.count]
            let variant = index % 24
            let key = ThreadKey(accountId: account.id, threadId: "ledger-ai-gold-\(index)")
            let source = now.addingTimeInterval(-Double(4 + index % 7) * 86_400)
            let person = "maya\(index)@example.com"
            let automated = [15, 16, 21].contains(variant)
            let fromMe = !automated && (variant < 12 ? positive[variant].1 : variant % 2 == 0)
            let body = variant < 12 ? positive[variant].0 : negative[variant - 12]
            let from = fromMe ? account.email : automated ? "noreply@example.com" : person
            let to = fromMe ? person : account.email
            messages.append(MailMessage(accountId: account.id, id: key.threadId + "-m0", threadId: key.threadId, date: source,
                fromName: fromMe ? "Alex" : "Maya Patel", fromEmail: from, toList: [Participant(name: fromMe ? "Maya Patel" : "Alex", email: to)],
                subject: "Launch planning \(index)", snippet: body, bodyText: body, bodyState: .full,
                labelIds: fromMe ? [SystemLabel.sent] : [SystemLabel.inbox], isFromMe: fromMe,
                listUnsubscribe: variant == 15 || variant == 21 ? "<mailto:unsubscribe@example.com>" : nil))
            var due = variant < 12 ? goldDue(body, source: source) : nil
            if variant < 12 {
                let followup: String
                if variant == 0 { followup = "Update: I will send the revised deck.pptx tomorrow instead."; due = goldDue(followup, source: source.addingTimeInterval(3600)) }
                else if variant == 1 { followup = "The W-9 request is withdrawn. You do not need to send it." }
                else { followup = "Thanks for the update." }
                messages.append(MailMessage(accountId: account.id, id: key.threadId + "-m1", threadId: key.threadId,
                    date: source.addingTimeInterval(3600), fromName: fromMe ? "Alex" : "Maya Patel", fromEmail: from,
                    toList: [Participant(name: fromMe ? "Maya Patel" : "Alex", email: to)], subject: "Launch planning \(index)",
                    snippet: followup, bodyText: followup + "\n\nFrom: " + from + "\n" + body,
                    bodyState: .full, labelIds: fromMe ? [SystemLabel.sent] : [SystemLabel.inbox], isFromMe: fromMe))
            }
            var target = LedgerAIGold(thread: key, direction: variant < 12 && variant != 1 ? positive[variant].2 : nil,
                counterparty: person, deliverableKeywords: variant < 12 ? positive[variant].3 : [], due: due, sourceIndex: variant == 0 ? 1 : 0, finalState: variant == 1 ? "withdrawn" : "open")
            // Either noun identifies the same action in these two compound requests.
            if variant == 4 { target.deliverableAlternatives = [["answers"]] }
            if variant == 5 { target.deliverableAlternatives = [["decision"]] }
            // The original promise and its reschedule both contain explicit fresh evidence.
            if variant == 0 { target.sourceAlternatives = [0] }
            gold.append(target)
        }
        try database.writer.write { db in
            for account in accounts { try account.upsert(db) }
            let keys = try MailStore.upsertMessages(db, messages)
            try MailStore.applyRules(db, keys: keys, now: now)
        }
        return gold
    }

    private static func goldDue(_ text: String, source: Date) -> String? {
        let calendar = Calendar.current
        var date: Date?
        if text.lowercased().contains("tomorrow") { date = calendar.date(byAdding: .day, value: 1, to: source) }
        else if text.contains("EOD") { date = source }
        else {
            for (offset, weekday) in ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"].enumerated() where text.contains(weekday) {
                let delta = (offset + 1 - calendar.component(.weekday, from: source) + 7) % 7
                date = calendar.date(byAdding: .day, value: delta == 0 ? 7 : delta, to: source)
            }
        }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone; formatter.dateFormat = "yyyy-MM-dd"
        return date.map(formatter.string)
    }
}
