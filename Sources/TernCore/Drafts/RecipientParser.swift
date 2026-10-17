import Foundation

/// Parses and checks addresses typed or pasted into a recipient field.
public enum RecipientParser {
    /// Splits a list such as `Maya Chen <maya@lumen.io>, "Ng, Jonas" <jonas@x.dev>; sam@y.co` into
    /// participants. Separators inside quotes or angle brackets are ignored. Invalid entries are kept
    /// (so the field can highlight them); check them with `isValidEmail`.
    public static func parse(_ text: String) -> [Participant] {
        segments(text).compactMap(participant)
    }

    /// Characters that end an entry outside quotes and angle brackets.
    public static let separators: Set<Character> = [",", ";", "\n", "\r", "\r\n"]

    /// For a field being typed into: the entries already ended by a separator, and the unfinished rest.
    public static func splitCompleted(_ text: String) -> (complete: [String], remainder: String) {
        var parts = rawSegments(text)
        let remainder = parts.removeLast()
        return (parts.flatMap(splitBareAddresses).filter { !$0.isEmpty }, remainder.trimmingCharacters(in: .whitespaces))
    }

    /// The separate entries of a list, trimmed, empty ones dropped. Whitespace between bare addresses
    /// also separates them ("a@b.co c@d.co").
    public static func segments(_ text: String) -> [String] {
        rawSegments(text).flatMap(splitBareAddresses).filter { !$0.isEmpty }
    }

    private static func splitBareAddresses(_ segment: String) -> [String] {
        let trimmed = segment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("<"), !trimmed.contains("\""), trimmed.contains(where: \.isWhitespace) else { return [trimmed] }
        let pieces = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
        return pieces.allSatisfy { $0.contains("@") } ? pieces : [trimmed]
    }

    /// Splits on unquoted separators, keeping every piece (the last may be empty).
    private static func rawSegments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false
        var angleDepth = 0
        for character in text {
            if character == "\"" {
                inQuotes.toggle()
            } else if !inQuotes, character == "<" {
                angleDepth += 1
            } else if !inQuotes, character == ">" {
                angleDepth = max(0, angleDepth - 1)
            } else if !inQuotes, angleDepth == 0, Self.separators.contains(character) {
                result.append(current)
                current = ""
                continue
            }
            current.append(character)
        }
        result.append(current)
        return result
    }

    /// One entry: `Name <email>`, `"Name" <email>`, `<email>`, `email`, or `mailto:email`.
    public static func participant(_ entry: String) -> Participant? {
        var text = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.lowercased().hasPrefix("mailto:") { text = String(text.dropFirst(7)) }
        if let open = text.lastIndex(of: "<"), let close = text.lastIndex(of: ">"), open < close {
            let email = String(text[text.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
            var name = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 { name = String(name.dropFirst().dropLast()) }
            name = name.replacingOccurrences(of: "\\\"", with: "\"")
            return Participant(name: name == email ? "" : name, email: email)
        }
        // "Maya Chen maya@lumen.io": a name, then the address.
        let words = text.split(whereSeparator: \.isWhitespace)
        if words.count > 1, let last = words.last, last.contains("@"), !words.dropLast().contains(where: { $0.contains("@") }) {
            return Participant(name: words.dropLast().joined(separator: " "), email: clean(String(last)))
        }
        // A bare address, possibly with stray quotes or trailing punctuation from prose.
        return Participant(email: clean(text))
    }

    private static func clean(_ address: String) -> String {
        address.trimmingCharacters(in: CharacterSet(charactersIn: "\"'()[] .:<>"))
    }

    /// A practical check, not RFC 5322: one `@`, a dot-separated domain with a 2+ letter TLD,
    /// no spaces or brackets.
    public static func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[0].count <= 64, email.count <= 254 else { return false }
        let local = parts[0], domain = parts[1]
        let forbidden = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "<>()[],;:\\\""))
        guard local.unicodeScalars.allSatisfy({ !forbidden.contains($0) }),
              !local.hasPrefix("."), !local.hasSuffix("."), !local.contains("..") else { return false }
        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else {
            return false
        }
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
        guard domain.unicodeScalars.allSatisfy({ allowed.contains($0) || $0 == "." }) else { return false }
        return (labels.last?.count ?? 0) >= 2 && labels.last!.allSatisfy(\.isLetter)
    }

    /// `Name <email>` (quoting the name when needed), or the bare address.
    public static func format(_ participant: Participant) -> String {
        guard !participant.name.isEmpty else { return participant.email }
        let needsQuotes = participant.name.contains(where: { ",;<>\"@".contains($0) })
        let name = needsQuotes ? "\"\(participant.name.replacingOccurrences(of: "\"", with: "\\\""))\"" : participant.name
        return "\(name) <\(participant.email)>"
    }

    /// Removes duplicates by address, case-insensitively, keeping the first occurrence (and its name,
    /// or a later name when the first had none).
    public static func deduplicated(_ people: [Participant], excluding: Set<String> = []) -> [Participant] {
        var seen: [String: Int] = [:]
        var result: [Participant] = []
        for person in people {
            let key = person.email.lowercased()
            guard !key.isEmpty, !excluding.contains(key) else { continue }
            if let index = seen[key] {
                if result[index].name.isEmpty { result[index].name = person.name }
                continue
            }
            seen[key] = result.count
            result.append(person)
        }
        return result
    }
}
