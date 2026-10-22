import Foundation
import GRDB
import TernCore

/// Validates citations against stored mail, never against model-supplied text.
struct LedgerVerdict {
    struct Update {
        var id: Int64
        var messageId: String?
        var date: Date?
        var note: String?
        var due: Date?
    }
    var thread: PromptThread
    var items: [LedgerExtraction]
    var updates: [Update]

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    static func date(_ text: String?, source: Date) -> Date? {
        guard let text, text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let value = formatter.date(from: text), formatter.string(from: value) == text,
              value >= source.addingTimeInterval(-86_400), value <= source.addingTimeInterval(365 * 86_400) else { return nil }
        return value
    }

    static func parse(_ text: String, db: Database, threads: [PromptThread], open: [ThreadKey: [Commitment]]) throws -> [LedgerVerdict]? {
        guard let root = ModelJSON.parse(text) as? [String: Any], let answers = root["threads"] as? [[String: Any]] else { return nil }
        let own = Set(try String.fetchAll(db, sql: "SELECT lower(email) FROM account"))
        var output: [LedgerVerdict] = []
        var seen = Set<String>()
        for answer in answers {
            guard let ref = Loose.string(answer["threadRef"]), let index = threads.indices.first(where: { "t\($0 + 1)" == ref }), seen.insert(ref).inserted,
                  let rawItems = answer["items"] as? [[String: Any]], let rawUpdates = answer["updates"] as? [[String: Any]] else { continue }
            let thread = threads[index]
            let stored = try MailMessage.filter(Column("accountId") == thread.key.accountId && Column("threadId") == thread.key.threadId).fetchAll(db)
            let byId = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
            let refs = Dictionary(uniqueKeysWithValues: thread.messages.enumerated().compactMap { offset, message -> (String, MailMessage)? in
                byId[message.id].map { ("\(ref).m\(offset + 1)", $0) }
            })
            let participants = Set(stored.flatMap { [$0.fromEmail] + ($0.toList + $0.ccList).map(\.email) }.map { $0.lowercased() })
            func evidence(_ message: MailMessage, _ quote: String) -> Bool {
                let raw = message.bodyText.flatMap { $0.isEmpty ? nil : $0 } ?? message.snippet
                let fresh = MailText.stripQuoted(raw)
                return normalized(quote).count >= 8 && normalized(fresh).contains(normalized(quote))
            }
            func direction(_ value: LedgerDirection, message: MailMessage, quote: String, counterparty: String) -> Bool {
                let q = quote.lowercased()
                let asks = q.range(of: #"\b(can you|could you|would you|will you|please|send me|need you to|let me know)\b"#, options: .regularExpression) != nil
                let promises = q.range(of: #"\b(i['’]ll|i will|we['’]ll|we will|will send|will get you|get back to you)\b"#, options: .regularExpression) != nil
                let recipients = Set((message.toList + message.ccList).map { $0.email.lowercased() })
                if message.isFromMe {
                    guard recipients.contains(counterparty) else { return false }
                    return value == .iOwe ? promises && !asks : asks
                }
                guard message.fromEmail.lowercased() == counterparty, !recipients.intersection(own).isEmpty else { return false }
                return value == .iOwe ? asks : promises && !asks
            }
            var items: [LedgerExtraction] = []
            for raw in rawItems {
                guard let d = Loose.string(raw["direction"]), ["owe", "waiting"].contains(d),
                      let counterparty = Loose.string(raw["counterparty"])?.lowercased(), participants.contains(counterparty), !own.contains(counterparty),
                      let deliverable = Loose.string(raw["deliverable"])?.trimmingCharacters(in: .whitespacesAndNewlines), (3...90).contains(deliverable.count),
                      deliverable.range(of: #"[a-z][a-z0-9+.-]*://|www\.|\b[a-z0-9-]+\.[a-z]{2,}(?:/|\b)"#, options: [.regularExpression, .caseInsensitive]) == nil,
                      let messageRef = Loose.string(raw["messageRef"]), let message = refs[messageRef],
                      let quote = Loose.string(raw["quote"]), evidence(message, quote),
                      let confidence = Loose.string(raw["confidence"]), ["high", "medium"].contains(confidence) else {
                    aiLog.debug("ledger: dropped invalid item"); continue
                }
                let value: LedgerDirection = d == "owe" ? .iOwe : .waitingOn
                guard direction(value, message: message, quote: quote, counterparty: counterparty) else { aiLog.debug("ledger: dropped inconsistent direction"); continue }
                let existingRef = Loose.string(raw["existingRef"])
                let existing = open[thread.key]?.first { "c\($0.id!)" == existingRef }
                guard existingRef == nil || existing != nil else { continue }
                items.append(LedgerExtraction(direction: value, counterparty: counterparty, deliverable: deliverable,
                    sourceMessageId: message.id, quote: quote, sourceDate: message.date,
                    dueAt: date(Loose.string(raw["dueDate"]), source: message.date), dueText: Loose.string(raw["dueText"]),
                    confidence: confidence == "high" ? 2 : 1, existingId: existing?.id))
            }
            var updates: [Update] = []
            for raw in rawUpdates {
                guard let item = open[thread.key]?.first(where: { "c\($0.id!)" == Loose.string(raw["ref"]) }), item.stateSource != "user",
                      let status = Loose.string(raw["status"]), ["open", "fulfilled", "withdrawn"].contains(status) else { continue }
                let due = date(Loose.string(raw["newDueDate"]), source: item.sourceDate)
                if status == "open" { if let due { updates.append(Update(id: item.id!, due: due)) }; continue }
                guard let ref = Loose.string(raw["resolvedByRef"]), let message = refs[ref], message.date > item.sourceDate,
                      let quote = Loose.string(raw["quote"]), evidence(message, quote) else { continue }
                let side = item.direction == .iOwe ? message.isFromMe && (message.toList + message.ccList).contains { $0.email.lowercased() == item.counterpartyEmail.lowercased() }
                    : !message.isFromMe && message.fromEmail.lowercased() == item.counterpartyEmail.lowercased()
                guard side else { continue }
                updates.append(Update(id: item.id!, messageId: message.id, date: message.date, note: "\(status): \(quote)", due: due))
            }
            output.append(LedgerVerdict(thread: thread, items: items, updates: updates))
        }
        return output
    }
}
