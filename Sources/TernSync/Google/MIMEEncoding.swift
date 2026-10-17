import Foundation
import TernCore

/// Header and body encodings for outgoing mail (RFC 2045, 2047, 2231, 5322).
enum MIMEEncoding {
    static let crlf = "\r\n"
    /// Lines are folded at 78 characters where possible; RFC 5322 forbids more than 998.
    static let foldWidth = 78

    // MARK: Headers

    /// Removes line breaks and other control characters so a value cannot inject headers.
    static func sanitize(_ value: String) -> String {
        String(String.UnicodeScalarView(value.unicodeScalars.map { scalar in
            scalar.properties.generalCategory == .control || scalar == "\u{2028}" || scalar == "\u{2029}" ? " " : scalar
        }))
    }

    static func isPlainASCII(_ text: String) -> Bool {
        text.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
    }

    /// RFC 2047 "B" encoded words, never splitting a character. Each is at most 68 characters
    /// (RFC 2047 allows 75) so "Subject: " plus one word fits a 78-character line.
    static func encodedWords(_ text: String) -> [String] {
        let prefix = "=?UTF-8?B?"
        let maxBytes = 42  // 56 base64 characters + 12 for the wrapper
        var words: [String] = []
        var chunk = Data()
        for character in text {
            let bytes = Data(String(character).utf8)
            if !chunk.isEmpty && chunk.count + bytes.count > maxBytes {
                words.append(prefix + chunk.base64EncodedString() + "?=")
                chunk = Data()
            }
            chunk.append(bytes)
        }
        if !chunk.isEmpty || words.isEmpty { words.append(prefix + chunk.base64EncodedString() + "?=") }
        return words
    }

    /// An unstructured header (Subject): plain ASCII folded at spaces, otherwise encoded words.
    static func unstructuredHeader(_ name: String, _ value: String) -> String {
        let value = sanitize(value)
        let longestWord = value.split(separator: " ").map(\.count).max() ?? 0
        let tokens: [String]
        if isPlainASCII(value), !value.contains("=?"), longestWord < 900 {
            tokens = value.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        } else {
            tokens = encodedWords(value)
        }
        return fold("\(name):", tokens, separator: " ")
    }

    /// Joins `tokens` after `head`, starting a continuation line (CRLF + space) before a token that
    /// would push the line past 78 characters.
    static func fold(_ head: String, _ tokens: [String], separator: String) -> String {
        var result = head
        var lineLength = head.count
        for (index, token) in tokens.enumerated() {
            let glue = index == 0 ? " " : separator
            if index > 0 && lineLength + glue.count + token.count > foldWidth {
                let trimmedGlue = glue.trimmingCharacters(in: .whitespaces)
                result += trimmedGlue + crlf + " " + token
                lineLength = 1 + token.count
            } else {
                result += glue + token
                lineLength += glue.count + token.count
            }
        }
        return result
    }

    /// `"Name" <email>`, `=?UTF-8?B?…?= <email>` or a bare address, as foldable pieces.
    static func mailboxTokens(_ participant: Participant) -> [String] {
        let email = sanitize(participant.email).trimmingCharacters(in: .whitespaces)
        let name = sanitize(participant.name).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != email else { return [email] }
        return phrase(name) + ["<\(email)>"]
    }

    /// A display name as an atom sequence, a quoted string, or encoded words.
    static func phrase(_ name: String) -> [String] {
        guard isPlainASCII(name), !name.contains("=?") else { return encodedWords(name) }
        let atext = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$%&'*+-/=?^_`{|}~ ")
        if name.unicodeScalars.allSatisfy({ atext.contains($0) }) { return [name] }
        let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return ["\"\(escaped)\""]
    }

    /// From/To/Cc/Bcc, folded between mailboxes and between encoded words. Nil when empty.
    static func addressHeader(_ name: String, _ participants: [Participant]) -> String? {
        let mailboxes = participants.filter { !$0.email.trimmingCharacters(in: .whitespaces).isEmpty }.map(mailboxTokens)
        guard !mailboxes.isEmpty else { return nil }
        var tokens: [String] = []
        for (index, var mailbox) in mailboxes.enumerated() {
            if index < mailboxes.count - 1 { mailbox[mailbox.count - 1] += "," }
            tokens += mailbox
        }
        return fold("\(name):", tokens, separator: " ")
    }

    /// A message id in angle brackets.
    static func messageId(_ id: String) -> String? {
        let trimmed = sanitize(id).trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("<") && trimmed.hasSuffix(">") { return trimmed }
        return "<\(trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>")))>"
    }

    /// Message ids found in a References / In-Reply-To value.
    static func messageIds(in value: String) -> [String] {
        var ids: [String] = []
        var rest = Substring(value)
        while let open = rest.firstIndex(of: "<"), let close = rest[open...].firstIndex(of: ">") {
            ids.append(String(rest[open...close]))
            rest = rest[rest.index(after: close)...]
        }
        if ids.isEmpty {
            ids = value.split(whereSeparator: { $0.isWhitespace || $0 == "," }).compactMap { messageId(String($0)) }
        }
        return ids
    }

    /// RFC 5322 date, e.g. "Fri, 17 Oct 2026 09:30:00 +0200".
    static func date(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        return formatter.string(from: date)
    }

    /// `; name="value"`, or RFC 2231 `name*=UTF-8''…` (split into `name*0*`, `name*1*`… when long)
    /// for non-ASCII and very long values. Each piece goes on its own folded line.
    static func parameter(_ name: String, _ value: String) -> String {
        let value = sanitize(value)
        if isPlainASCII(value), value.count <= 60 {
            let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return ";\(crlf) \(name)=\"\(escaped)\""
        }
        let attrChars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~")
        var pieces: [String] = []
        var piece = "UTF-8''"
        for character in value {
            let encoded = String(character).addingPercentEncoding(withAllowedCharacters: attrChars) ?? ""
            if piece.count + encoded.count > 60 {
                pieces.append(piece)
                piece = ""
            }
            piece += encoded
        }
        pieces.append(piece)
        if pieces.count == 1 { return ";\(crlf) \(name)*=\(pieces[0])" }
        return pieces.enumerated().map { ";\(crlf) \(name)*\($0.offset)*=\($0.element)" }.joined()
    }

    // MARK: Bodies

    /// base64 in 76-character lines ending in CRLF.
    static func base64Lines(_ data: Data) -> String {
        guard !data.isEmpty else { return "" }
        return data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed]) + crlf
    }

    /// Quoted-printable (RFC 2045 §6.7) of UTF-8 text. Line breaks become CRLF hard breaks; encoded
    /// lines stay within 76 characters using "=" soft breaks.
    static func quotedPrintable(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var out = ""
        for (lineIndex, line) in lines.enumerated() {
            let bytes = Array(line.utf8)
            var length = 0
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                let literal = (byte >= 0x21 && byte <= 0x7E && byte != UInt8(ascii: "="))
                    || ((byte == 0x20 || byte == 0x09) && !isLast)
                let token = literal ? String(UnicodeScalar(byte)) : String(format: "=%02X", byte)
                if length + token.count > 75 {
                    out += "=" + crlf
                    length = 0
                }
                out += token
                length += token.count
            }
            if lineIndex < lines.count - 1 { out += crlf }
        }
        return out + crlf
    }

    /// Picks the shorter transfer encoding for text: quoted-printable unless most bytes are non-ASCII.
    static func encodeText(_ text: String) -> (encoding: String, body: String) {
        let bytes = text.utf8
        let nonASCII = bytes.reduce(0) { $0 + ($1 >= 0x80 ? 1 : 0) }
        if nonASCII * 3 > bytes.count {
            return ("base64", base64Lines(Data(bytes)))
        }
        return ("quoted-printable", quotedPrintable(text))
    }
}
