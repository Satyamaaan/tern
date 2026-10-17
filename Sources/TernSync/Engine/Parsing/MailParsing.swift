import CoreFoundation
import Foundation

/// Decoding helpers for Gmail payloads: base64url, charsets, RFC 2047 encoded words, RFC 2231
/// parameters, RFC 5322 address lists and HTML-to-text. Pure functions, safe from any thread.
public enum MailParsing {}

// MARK: - Base64url

extension MailParsing {
    /// Decodes base64url (or standard base64), with or without padding and line breaks.
    public static func base64URLDecode(_ string: String) -> Data? {
        var bytes = [UInt8]()
        bytes.reserveCapacity(string.utf8.count + 3)
        for byte in string.utf8 {
            switch byte {
            case UInt8(ascii: "-"): bytes.append(UInt8(ascii: "+"))
            case UInt8(ascii: "_"): bytes.append(UInt8(ascii: "/"))
            case UInt8(ascii: "="), UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): continue
            default: bytes.append(byte)
            }
        }
        switch bytes.count % 4 {
        case 1: bytes.removeLast()
        case 2: bytes.append(contentsOf: [UInt8(ascii: "="), UInt8(ascii: "=")])
        case 3: bytes.append(UInt8(ascii: "="))
        default: break
        }
        return Data(base64Encoded: Data(bytes))
    }

    /// Unpadded base64url, as Gmail returns it.
    public static func base64URLEncode(_ data: Data) -> String {
        var string = data.base64EncodedString()
        string = string.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        while string.hasSuffix("=") { string.removeLast() }
        return string
    }
}

// MARK: - Raw messages

extension MailParsing {
    /// Sets a header on an RFC 822 message, replacing every existing one of that name (with its
    /// folded continuation lines). The header goes first; the body is untouched.
    public static func settingHeader(_ name: String, to value: String, in raw: Data) -> Data {
        let bytes = [UInt8](raw)
        var headerEnd = bytes.count
        var bodyStart = bytes.count
        var index = 0
        while index < bytes.count {
            if bytes[index] == 0x0A, index + 1 < bytes.count, bytes[index + 1] == 0x0A {
                headerEnd = index
                bodyStart = index + 2
                break
            }
            if bytes[index] == 0x0D, index + 3 < bytes.count, bytes[index + 1] == 0x0A, bytes[index + 2] == 0x0D, bytes[index + 3] == 0x0A {
                headerEnd = index
                bodyStart = index + 4
                break
            }
            index += 1
        }
        let headerText = String(decoding: bytes[..<headerEnd], as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var kept: [String] = []
        var skipping = false
        for line in headerText.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.first == " " || line.first == "\t" {
                if !skipping { kept.append(String(line)) }
                continue
            }
            let field = line.split(separator: ":", maxSplits: 1).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            skipping = field.caseInsensitiveCompare(name) == .orderedSame
            if !skipping { kept.append(String(line)) }
        }
        let header = (["\(name): \(value)"] + kept).joined(separator: "\r\n") + "\r\n\r\n"
        return Data(header.utf8) + Data(bytes[min(bodyStart, bytes.count)...])
    }
}

// MARK: - Charsets

extension MailParsing {
    /// Supersets mail clients use in place of what the header claims.
    private static let charsetAliases: [String: String] = [
        "gb2312": "gb18030", "gbk": "gb18030", "x-gbk": "gb18030", "cn-gb": "gb18030",
        "shift_jis": "windows-31j", "x-sjis": "windows-31j", "sjis": "windows-31j",
        "ks_c_5601-1987": "windows-949", "euc-kr": "windows-949",
        "utf8": "utf-8", "cp1252": "windows-1252", "x-cp1252": "windows-1252",
    ]

    /// The string encoding for an IANA charset name (as used in Content-Type), or nil when unknown.
    public static func encoding(forCharset charset: String) -> String.Encoding? {
        let name = normalizedCharset(charset)
        guard !name.isEmpty else { return nil }
        switch name {
        case "utf-8": return .utf8
        case "us-ascii", "ascii": return .ascii
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }

    /// Decodes text in the given charset, falling back to UTF-8 and then Latin-1 (which never fails).
    /// Like browsers, text labelled Latin-1 is read as Windows-1252 and text labelled ASCII as UTF-8.
    public static func decodeText(_ data: Data, charset: String?) -> String {
        let name = charset.map(normalizedCharset) ?? ""
        switch name {
        case "", "utf-8", "us-ascii", "ascii", "ansi_x3.4-1968":
            break
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "windows-1252":
            if let string = String(data: data, encoding: .windowsCP1252) { return string }
            return String(data: data, encoding: .isoLatin1) ?? ""
        default:
            if let encoding = encoding(forCharset: name), let string = String(data: data, encoding: encoding) {
                return string
            }
        }
        if let string = String(data: data, encoding: .utf8) { return string }
        return String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self)
    }

    static func normalizedCharset(_ charset: String) -> String {
        var name = charset.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
            .lowercased()
        // RFC 2231 language suffix: utf-8*en
        if let star = name.firstIndex(of: "*") { name = String(name[..<star]) }
        return charsetAliases[name] ?? name
    }
}

// MARK: - RFC 2047 encoded words

extension MailParsing {
    /// Removes header folding (CRLF followed by whitespace).
    public static func unfold(_ value: String) -> String {
        guard value.contains(where: \.isNewline) else { return value }
        return value.replacingOccurrences(of: "\r\n", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
    }

    /// Unfolds a header value and decodes RFC 2047 encoded words (B and Q, any charset). Whitespace
    /// between adjacent encoded words is dropped, and adjacent words in one charset are decoded
    /// together so multibyte characters split across words survive.
    public static func decodeHeader(_ raw: String) -> String {
        let value = unfold(raw)
        guard value.contains("=?") else { return value }

        enum Token {
            case text(String)
            case word(charset: String, bytes: [UInt8])
        }
        var tokens: [Token] = []
        var text = ""
        var index = value.startIndex
        while index < value.endIndex {
            if value[index] == "=", let word = encodedWord(in: value, at: index) {
                if !text.isEmpty { tokens.append(.text(text)); text = "" }
                tokens.append(.word(charset: word.charset, bytes: word.bytes))
                index = word.end
            } else {
                text.append(value[index])
                index = value.index(after: index)
            }
        }
        if !text.isEmpty { tokens.append(.text(text)) }

        func isWord(_ position: Int) -> Bool {
            guard tokens.indices.contains(position), case .word = tokens[position] else { return false }
            return true
        }

        var output = ""
        var run: (charset: String, bytes: [UInt8])?
        func flush() {
            if let current = run { output += decodeText(Data(current.bytes), charset: current.charset) }
            run = nil
        }
        for (position, token) in tokens.enumerated() {
            switch token {
            case .word(let charset, let bytes):
                if run?.charset == charset {
                    run?.bytes += bytes
                } else {
                    flush()
                    run = (charset, bytes)
                }
            case .text(let string):
                if isWord(position - 1), isWord(position + 1), string.allSatisfy({ $0 == " " || $0 == "\t" }) {
                    continue
                }
                flush()
                output += string
            }
        }
        flush()
        return output
    }

    private static func encodedWord(in value: String, at start: String.Index) -> (charset: String, bytes: [UInt8], end: String.Index)? {
        guard value[start...].hasPrefix("=?") else { return nil }
        let charsetStart = value.index(start, offsetBy: 2)
        guard let charsetEnd = value[charsetStart...].firstIndex(of: "?") else { return nil }
        let charset = value[charsetStart..<charsetEnd]
        guard !charset.isEmpty, !charset.contains(where: { $0.isWhitespace || $0 == "=" }) else { return nil }
        let encodingIndex = value.index(after: charsetEnd)
        guard encodingIndex < value.endIndex else { return nil }
        let encoding = value[encodingIndex]
        let separator = value.index(after: encodingIndex)
        guard separator < value.endIndex, value[separator] == "?" else { return nil }
        let textStart = value.index(after: separator)
        guard let close = value[textStart...].range(of: "?=") else { return nil }
        let encoded = value[textStart..<close.lowerBound]
        guard !encoded.contains(where: \.isWhitespace) else { return nil }

        let bytes: [UInt8]?
        switch encoding {
        case "B", "b": bytes = base64URLDecode(String(encoded)).map { [UInt8]($0) }
        case "Q", "q": bytes = quotedPrintableBytes(encoded, underscoreIsSpace: true)
        default: bytes = nil
        }
        guard let bytes else { return nil }
        return (normalizedCharset(String(charset)), bytes, close.upperBound)
    }

    /// Decodes `=XX` escapes. In encoded words `_` stands for a space.
    static func quotedPrintableBytes(_ text: Substring, underscoreIsSpace: Bool) -> [UInt8] {
        let utf8 = Array(text.utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(utf8.count)
        var index = 0
        while index < utf8.count {
            let byte = utf8[index]
            if byte == UInt8(ascii: "="), index + 2 < utf8.count,
               let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else if byte == UInt8(ascii: "_"), underscoreIsSpace {
                bytes.append(0x20)
                index += 1
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return bytes
    }

    static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): byte - UInt8(ascii: "0")
        case UInt8(ascii: "a")...UInt8(ascii: "f"): byte - UInt8(ascii: "a") + 10
        case UInt8(ascii: "A")...UInt8(ascii: "F"): byte - UInt8(ascii: "A") + 10
        default: nil
        }
    }
}

// MARK: - RFC 2045 / 2231 parameters

extension MailParsing {
    /// A header like Content-Type or Content-Disposition: the value plus its parameters.
    public struct ParameterizedValue: Sendable, Hashable {
        /// Lowercased, e.g. "text/html" or "attachment".
        public var value: String
        /// Lowercased names; RFC 2231 continuations and charsets already joined and decoded.
        public var parameters: [String: String]
    }

    public static func parameterizedValue(_ raw: String) -> ParameterizedValue {
        let segments = splitOutsideQuotes(unfold(raw), separator: ";")
        let value = (segments.first ?? "").trimmingCharacters(in: .whitespaces).lowercased()

        struct Piece { var index: Int; var extended: Bool; var text: String }
        var plain: [String: String] = [:]
        var pieces: [String: [Piece]] = [:]
        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            let name = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            let rawValue = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            let text = unquote(rawValue)
            guard name.contains("*") else {
                plain[name] = text
                continue
            }
            let parts = name.split(separator: "*", omittingEmptySubsequences: false)
            let base = String(parts[0])
            let extended = name.hasSuffix("*")
            let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
            pieces[base, default: []].append(Piece(index: index, extended: extended, text: text))
        }

        var parameters = plain
        for (base, list) in pieces {
            var charset = "utf-8"
            var bytes: [UInt8] = []
            for (position, piece) in list.sorted(by: { $0.index < $1.index }).enumerated() {
                guard piece.extended else {
                    bytes += Array(piece.text.utf8)
                    continue
                }
                var text = Substring(piece.text)
                if position == 0 {
                    let fields = text.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                    if fields.count == 3 {
                        if !fields[0].isEmpty { charset = String(fields[0]) }
                        text = fields[2]
                    }
                }
                bytes += percentDecoded(text)
            }
            parameters[base] = decodeText(Data(bytes), charset: charset)
        }
        return ParameterizedValue(value: value, parameters: parameters)
    }

    static func percentDecoded(_ text: Substring) -> [UInt8] {
        let utf8 = Array(text.utf8)
        var bytes: [UInt8] = []
        var index = 0
        while index < utf8.count {
            if utf8[index] == UInt8(ascii: "%"), index + 2 < utf8.count,
               let high = hexValue(utf8[index + 1]), let low = hexValue(utf8[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(utf8[index])
                index += 1
            }
        }
        return bytes
    }

    static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        var result = ""
        var escaped = false
        for character in value.dropFirst().dropLast() {
            if escaped { result.append(character); escaped = false } else if character == "\\" { escaped = true } else { result.append(character) }
        }
        return result
    }

    static func splitOutsideQuotes(_ value: String, separator: Character) -> [String] {
        var segments: [String] = []
        var current = ""
        var inQuote = false
        var escaped = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && inQuote { current.append(character); escaped = true; continue }
            if character == "\"" { inQuote.toggle() }
            if character == separator && !inQuote {
                segments.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        segments.append(current)
        return segments
    }
}
