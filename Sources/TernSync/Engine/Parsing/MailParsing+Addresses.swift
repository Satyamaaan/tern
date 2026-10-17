import Foundation
import TernCore

extension MailParsing {
    /// Parses an RFC 5322 address list: quoted names containing commas, groups (`Team: a@x, b@y;`),
    /// comments (`a@x (Ann)`), bare and angle-only addresses, and encoded-word names. Entries without
    /// an address are skipped; an unquoted `Doe, John <j@x>` is read as one mailbox.
    public static func addresses(_ raw: String) -> [Participant] {
        let value = unfold(raw)
        var items: [String] = []
        var current = ""
        var inQuote = false, escaped = false, inAngle = false, inGroup = false
        var commentDepth = 0

        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && (inQuote || commentDepth > 0) { current.append(character); escaped = true; continue }
            if inQuote {
                if character == "\"" { inQuote = false }
                current.append(character)
                continue
            }
            if commentDepth > 0 {
                if character == "(" { commentDepth += 1 } else if character == ")" { commentDepth -= 1 }
                current.append(character)
                continue
            }
            switch character {
            case "\"": inQuote = true; current.append(character)
            case "(": commentDepth = 1; current.append(character)
            case "<": inAngle = true; current.append(character)
            case ">": inAngle = false; current.append(character)
            case "," where !inAngle:
                items.append(current); current = ""
            case ":" where !inAngle && !inGroup:
                // The group's display name; its members follow.
                inGroup = true; current = ""
            case ";" where !inAngle && inGroup:
                items.append(current); current = ""; inGroup = false
            default:
                current.append(character)
            }
        }
        items.append(current)

        var result: [Participant] = []
        var carry = ""
        for item in items {
            let trimmed = item.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let candidate = carry.isEmpty ? trimmed : carry + ", " + trimmed
            if let participant = mailbox(candidate) {
                result.append(participant)
                carry = ""
            } else if !trimmed.contains("@") {
                carry = candidate
            } else {
                carry = ""
            }
        }
        return result
    }

    /// One `name <addr>`, `addr (comment)` or bare `addr`.
    private static func mailbox(_ item: String) -> Participant? {
        var phrase = ""
        var comments: [String] = []
        var comment = ""
        var angle: String?
        var angleBuffer = ""
        var inQuote = false, escaped = false, inAngle = false
        var depth = 0

        for character in item {
            if depth > 0 {
                if escaped { comment.append(character); escaped = false; continue }
                switch character {
                case "\\": escaped = true
                case "(": depth += 1; comment.append(character)
                case ")":
                    depth -= 1
                    if depth == 0 { comments.append(comment); comment = "" } else { comment.append(character) }
                default: comment.append(character)
                }
                continue
            }
            if inAngle {
                if character == ">" { inAngle = false; angle = angleBuffer } else { angleBuffer.append(character) }
                continue
            }
            if inQuote {
                if escaped { phrase.append(character); escaped = false; continue }
                switch character {
                case "\\": escaped = true
                case "\"": inQuote = false
                default: phrase.append(character)
                }
                continue
            }
            switch character {
            case "\"": inQuote = true
            case "(": depth = 1
            case "<": inAngle = true; angleBuffer = ""
            default: phrase.append(character)
            }
        }
        if inAngle { angle = angleBuffer }

        var email: String
        var name: String
        if let angle {
            email = angle
            // Obsolete source route: <@relay.example:ann@example.com>
            if email.hasPrefix("@"), let colon = email.lastIndex(of: ":") { email = String(email[email.index(after: colon)...]) }
            name = phrase
        } else {
            email = phrase
            name = comments.first ?? ""
        }
        email = email.filter { !$0.isWhitespace }
        guard !email.isEmpty, email.contains("@") || angle != nil else { return nil }

        name = decodeHeader(collapseWhitespace(name)).trimmingCharacters(in: .whitespaces)
        if name.count >= 2, name.hasPrefix("'"), name.hasSuffix("'") { name = String(name.dropFirst().dropLast()) }
        if name.caseInsensitiveCompare(email) == .orderedSame { name = "" }
        return Participant(name: name, email: email)
    }

    static func collapseWhitespace(_ text: String) -> String {
        var result = ""
        var lastWasSpace = false
        for character in text {
            if character.isWhitespace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }
}
