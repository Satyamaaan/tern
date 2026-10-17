import Foundation
import TernCore

/// One thread's verdict from the model, validated and clamped.
struct TriageVerdict: Hashable, Sendable {
    var ref: String
    var category: MailCategory
    var needsReply: Bool
    var priority: Int
    var summary: String?
    /// A known project id, or nil.
    var project: String?

    static let summaryLimit = 110

    /// Parses `{"items":[…]}` (or a bare array). Unknown refs are dropped; nil when nothing is readable.
    static func parse(_ text: String, refs: Set<String>, projects: [Project]) -> [TriageVerdict]? {
        guard let root = ModelJSON.parse(text) else { return nil }
        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let object = root as? [String: Any], let array = (object["items"] ?? object["threads"] ?? object["results"]) as? [Any] {
            items = array
        } else {
            return nil
        }
        var verdicts: [String: TriageVerdict] = [:]
        for case let item as [String: Any] in items {
            guard let ref = Loose.string(item["threadKey"] ?? item["ref"] ?? item["id"])?.trimmingCharacters(in: .whitespaces),
                  refs.contains(ref), verdicts[ref] == nil
            else { continue }
            verdicts[ref] = TriageVerdict(
                ref: ref,
                category: category(Loose.string(item["category"])),
                needsReply: Loose.bool(item["needsReply"]) ?? false,
                priority: min(3, max(0, Loose.int(item["priority"]) ?? 1)),
                summary: summary(Loose.string(item["summary"])),
                project: project(Loose.string(item["project"]), in: projects))
        }
        return Array(verdicts.values)
    }

    static func category(_ value: String?) -> MailCategory {
        guard let value = value?.lowercased().trimmingCharacters(in: .whitespaces) else { return .other }
        if let category = MailCategory(rawValue: value) { return category }
        let synonyms: [String: MailCategory] = [
            "person": .people, "personal": .people, "human": .people, "notifications": .notification,
            "alert": .notification, "newsletters": .newsletter, "receipts": .receipt, "invoice": .receipt,
            "order": .receipt, "event": .calendar, "invite": .calendar, "promotions": .promotion,
            "marketing": .promotion, "promo": .promotion, "otp": .security, "auth": .security,
        ]
        return synonyms[value] ?? .other
    }

    /// One plain line, at most `summaryLimit` characters; nil when empty.
    static func summary(_ value: String?) -> String? {
        guard var text = value else { return nil }
        text = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`*-•"))
        text = MailText.compact(text, limit: summaryLimit)
        return text.isEmpty ? nil : text
    }

    static func project(_ value: String?, in projects: [Project]) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if let match = projects.first(where: { $0.id == value }) { return match.id }
        return projects.first { $0.name.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.id
    }
}
