import Foundation
import GRDB
import TernCore

/// Validates citations against stored mail, never against model-supplied text.
struct LedgerVerdict {
    private struct Message: TernRecord {
        var id: String
        var date: Date
        var fromName: String
        var fromEmail: String
        var toList: [Participant]
        var ccList: [Participant]
        var snippet: String
        var bodyText: String?
        var isFromMe: Bool
    }

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

    static func containsURL(_ text: String) -> Bool {
        text.range(of: #"://|www\.|\b[a-z0-9-]+\.(?:com|org|net|io|dev|app|co|edu|gov)(?:/|\b)"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func date(_ text: String?, source: Date, calendar: Calendar = .current) -> Date? {
        guard let text, text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = calendar.timeZone
        formatter.calendar = calendar
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let value = formatter.date(from: text), formatter.string(from: value) == text,
              (calendar.dateComponents([.day], from: calendar.startOfDay(for: source), to: calendar.startOfDay(for: value)).day).map { (-1...365).contains($0) } == true else { return nil }
        return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: value)
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
            let ids = thread.messages.map(\.id)
            let slots = ids.map { _ in "?" }.joined(separator: ",")
            let stored = try Message.fetchAll(db, sql: """
                SELECT id,date,fromName,fromEmail,toList,ccList,snippet,substr(bodyText,1,6000) AS bodyText,isFromMe
                FROM message WHERE accountId=? AND threadId=? AND id IN (\(slots)) LIMIT 4
                """, arguments: StatementArguments([thread.key.accountId, thread.key.threadId] + ids))
            let byId = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
            let refs = Dictionary(uniqueKeysWithValues: thread.messages.enumerated().compactMap { offset, message -> (String, Message)? in
                byId[message.id].map { ("\(ref).m\(offset + 1)", $0) }
            })
            let participants = Set(stored.flatMap { [$0.fromEmail] + ($0.toList + $0.ccList).map(\.email) }.map { $0.lowercased() })
            func evidence(_ message: Message, _ quote: String) -> Bool {
                let raw = message.bodyText.flatMap { $0.isEmpty ? nil : $0 } ?? message.snippet
                let fresh = MailText.stripQuoted(raw)
                return normalized(quote).count >= min(20, normalized(fresh).count) && !normalized(quote).isEmpty && normalized(fresh).contains(normalized(quote))
            }
            func direction(_ value: LedgerDirection, message: Message, quote: String, counterparty: String) -> Bool {
                let q = quote.lowercased().replacingOccurrences(of: "please find attached", with: "attached")
                let asks = q.range(of: #"\b(can you|could you|would you|will you|please|send me|need you to|let me know)\b"#, options: .regularExpression) != nil
                let promises = q.range(of: #"\b(i['’]ll|i will|we['’]ll|we will|will send|will get you|get back to you)\b"#, options: .regularExpression) != nil
                let recipients = Set((message.toList + message.ccList).map { $0.email.lowercased() })
                if message.isFromMe {
                    guard recipients.contains(counterparty) else { return false }
                    return value == .iOwe ? promises : asks
                }
                guard message.fromEmail.lowercased() == counterparty, !recipients.intersection(own).isEmpty else { return false }
                if value == .iOwe {
                    let greeting = normalized(MailText.stripQuoted(message.bodyText.flatMap { $0.isEmpty ? nil : $0 } ?? message.snippet))
                    let targetsOther = (message.toList + message.ccList).filter { !own.contains($0.email.lowercased()) }.contains { person in
                        let name = person.name.split(separator: " ").first.map(String.init) ?? MailText.localPart(of: person.email)
                        return greeting.hasPrefix(name.lowercased() + ",") || greeting.hasPrefix("hi " + name.lowercased()) || greeting.hasPrefix("dear " + name.lowercased())
                    }
                    if targetsOther { return false }
                }
                return value == .iOwe ? asks : promises
            }
            var items: [LedgerExtraction] = []
            for raw in rawItems {
                guard let d = Loose.string(raw["direction"]), ["owe", "waiting"].contains(d),
                      let counterparty = Loose.string(raw["counterparty"])?.lowercased(), participants.contains(counterparty), !own.contains(counterparty),
                      let phrase = Loose.string(raw["deliverable"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                      case let deliverable = phrase.prefix(1).uppercased() + phrase.dropFirst(), (3...90).contains(deliverable.count),
                      !containsURL(deliverable),
                      let messageRef = Loose.string(raw["messageRef"]), let message = refs[messageRef],
                      let quote = Loose.string(raw["quote"]), evidence(message, quote),
                      let confidence = Loose.string(raw["confidence"]), ["high", "medium"].contains(confidence) else {
                    aiLog.debug("ledger: dropped invalid item"); continue
                }
                let value: LedgerDirection = d == "owe" ? .iOwe : .waitingOn
                let fresh = MailText.stripQuoted(message.bodyText.flatMap { $0.isEmpty ? nil : $0 } ?? message.snippet)
                let words = Ledger.tokens(deliverable)
                let sourceWords = Ledger.tokens(fresh)
                let objectWords = words.subtracting(["send", "get", "share", "review", "sign", "deliver", "reply", "provide"])
                guard !objectWords.isEmpty, objectWords.isSubset(of: sourceWords),
                      words.intersection(sourceWords).count >= min(2, words.count) else { continue }
                guard !Ledger.isAutomation(message.fromEmail), !Ledger.isAutomation(counterparty) else { continue }
                guard direction(value, message: message, quote: quote, counterparty: counterparty) else { aiLog.debug("ledger: dropped inconsistent direction"); continue }
                let existingRef = Loose.string(raw["existingRef"])
                let existing = open[thread.key]?.first { "c\($0.id!)" == existingRef }
                guard existingRef == nil || existing != nil else { continue }
                if existing == nil {
                    let objectWords = words.subtracting(["send", "get", "share", "review", "sign", "deliver", "reply", "provide"])
                    let withdrawn = stored.contains { later in
                        guard later.date > message.date else { return false }
                        let requester = value == .iOwe ? !later.isFromMe && later.fromEmail.lowercased() == counterparty
                            : later.isFromMe && (later.toList + later.ccList).contains { $0.email.lowercased() == counterparty }
                        let text = MailText.stripQuoted(later.bodyText.flatMap { $0.isEmpty ? nil : $0 } ?? later.snippet)
                        return requester && text.range(of: #"\b(withdrawn|cancelled|canceled|no longer need|do not need|don['’]t need)\b"#, options: [.regularExpression, .caseInsensitive]) != nil
                            && !objectWords.intersection(Ledger.tokens(text)).isEmpty
                    }
                    if withdrawn { continue }
                }
                var extraction = LedgerExtraction(direction: value, counterparty: counterparty, deliverable: deliverable,
                    sourceMessageId: message.id, quote: quote, sourceDate: message.date,
                    dueAt: date(Loose.string(raw["dueDate"]), source: message.date), dueText: Loose.string(raw["dueText"]),
                    confidence: confidence == "high" ? 2 : 1, existingId: existing?.id)
                extraction.counterpartyName = message.isFromMe ? ((message.toList + message.ccList).first { $0.email.lowercased() == counterparty }?.name ?? "") : message.fromName
                items.append(extraction)
            }
            var updates: [Update] = []
            for raw in rawUpdates {
                guard let item = open[thread.key]?.first(where: { "c\($0.id!)" == Loose.string(raw["ref"]) }), item.stateSource != "user",
                      let status = Loose.string(raw["status"]), ["open", "fulfilled", "withdrawn"].contains(status) else { continue }
                let due = date(Loose.string(raw["newDueDate"]), source: item.sourceDate)
                if status == "open" && due == nil { continue }
                guard let ref = Loose.string(raw["resolvedByRef"]), let message = refs[ref], message.date > item.sourceDate,
                      let quote = Loose.string(raw["quote"]), evidence(message, quote) else { continue }
                let side = item.direction == .iOwe ? message.isFromMe && (message.toList + message.ccList).contains { $0.email.lowercased() == item.counterpartyEmail.lowercased() }
                    : !message.isFromMe && message.fromEmail.lowercased() == item.counterpartyEmail.lowercased()
                let opposite = item.direction == .iOwe
                    ? !message.isFromMe && message.fromEmail.lowercased() == item.counterpartyEmail.lowercased()
                    : message.isFromMe && (message.toList + message.ccList).contains { $0.email.lowercased() == item.counterpartyEmail.lowercased() }
                guard status == "withdrawn" ? opposite : side else { continue }
                updates.append(Update(id: item.id!, messageId: message.id, date: message.date, note: "\(status): \(quote)", due: due))
            }
            output.append(LedgerVerdict(thread: thread, items: items, updates: updates))
        }
        return output
    }
}
