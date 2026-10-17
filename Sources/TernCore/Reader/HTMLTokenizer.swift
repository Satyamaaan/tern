import Foundation

struct HTMLAttribute: Hashable, Sendable {
    /// Lowercased.
    var name: String
    /// Character references already decoded.
    var value: String
}

enum HTMLToken {
    /// Text exactly as written; character references are left in place.
    case text(String)
    case startTag(String, [HTMLAttribute], selfClosing: Bool)
    case endTag(String)
    /// Contents of a raw-text element (`style`, `script`, `title`…), delivered right after its start tag.
    case rawText(String)
}

/// A forgiving tokenizer over UTF-8 bytes, following HTML5 closely enough that the tree we build
/// matches what WebKit builds for the same markup. Comments, doctypes and processing instructions
/// are dropped.
enum HTMLTokenizer {
    static let rawTextElements: Set<String> = [
        "script", "style", "xmp", "iframe", "noembed", "noframes", "noscript", "textarea", "title", "plaintext",
    ]

    static func tokenize(_ html: String, _ emit: (HTMLToken) -> Void) {
        let bytes = Array(html.utf8)
        bytes.withUnsafeBufferPointer { buffer in
            var scanner = Scanner(bytes: buffer)
            scanner.run(emit)
        }
    }

    private struct Scanner {
        let bytes: UnsafeBufferPointer<UInt8>
        var index = 0
        var textStart = 0

        var count: Int { bytes.count }

        mutating func run(_ emit: (HTMLToken) -> Void) {
            while index < count {
                guard bytes[index] == UInt8(ascii: "<"), index + 1 < count else {
                    index += 1
                    continue
                }
                let next = bytes[index + 1]
                if next == UInt8(ascii: "!") {
                    flushText(upTo: index, emit)
                    index = skipMarkupDeclaration(from: index + 2)
                    textStart = index
                } else if next == UInt8(ascii: "?") {
                    flushText(upTo: index, emit)
                    index = afterNext(UInt8(ascii: ">"), from: index + 2)
                    textStart = index
                } else if next == UInt8(ascii: "/") {
                    guard index + 2 < count else { index += 2; continue }
                    let third = bytes[index + 2]
                    flushText(upTo: index, emit)
                    if isAlpha(third) {
                        var cursor = index + 2
                        let name = readName(&cursor)
                        var ignored: [HTMLAttribute] = []
                        var selfClosing = false
                        index = readAttributes(from: cursor, into: &ignored, selfClosing: &selfClosing)
                        emit(.endTag(name))
                    } else if third == UInt8(ascii: ">") {
                        index += 3
                    } else {
                        index = afterNext(UInt8(ascii: ">"), from: index + 2)
                    }
                    textStart = index
                } else if isAlpha(next) {
                    flushText(upTo: index, emit)
                    var cursor = index + 1
                    let name = readName(&cursor)
                    var attributes: [HTMLAttribute] = []
                    var selfClosing = false
                    index = readAttributes(from: cursor, into: &attributes, selfClosing: &selfClosing)
                    emit(.startTag(name, attributes, selfClosing: selfClosing))
                    textStart = index
                    if HTMLTokenizer.rawTextElements.contains(name) {
                        readRawText(of: name, emit)
                    }
                } else {
                    index += 1
                }
            }
            flushText(upTo: count, emit)
        }

        mutating func flushText(upTo end: Int, _ emit: (HTMLToken) -> Void) {
            guard end > textStart else { return }
            emit(.text(string(textStart, end)))
            textStart = end
        }

        mutating func readRawText(of name: String, _ emit: (HTMLToken) -> Void) {
            let start = index
            if name == "plaintext" {
                if count > start { emit(.rawText(string(start, count))) }
                index = count
                textStart = count
                return
            }
            let nameBytes = Array(name.utf8)
            var cursor = start
            var end = count
            search: while cursor + 1 < count {
                if bytes[cursor] == UInt8(ascii: "<"), bytes[cursor + 1] == UInt8(ascii: "/") {
                    var matched = true
                    for (offset, byte) in nameBytes.enumerated() {
                        let position = cursor + 2 + offset
                        if position >= count || lower(bytes[position]) != byte { matched = false; break }
                    }
                    if matched {
                        let after = cursor + 2 + nameBytes.count
                        if after >= count || isSpace(bytes[after]) || bytes[after] == UInt8(ascii: "/") || bytes[after] == UInt8(ascii: ">") {
                            end = cursor
                            break search
                        }
                    }
                }
                cursor += 1
            }
            if end > start { emit(.rawText(string(start, end))) }
            if end < count {
                var ignored: [HTMLAttribute] = []
                var selfClosing = false
                index = readAttributes(from: end + 2 + nameBytes.count, into: &ignored, selfClosing: &selfClosing)
                emit(.endTag(name))
            } else {
                index = count
            }
            textStart = index
        }

        /// After `<!`: comments, doctypes, CDATA and bogus comments.
        func skipMarkupDeclaration(from start: Int) -> Int {
            if start + 1 < count, bytes[start] == UInt8(ascii: "-"), bytes[start + 1] == UInt8(ascii: "-") {
                var cursor = start + 2
                if cursor < count, bytes[cursor] == UInt8(ascii: ">") { return cursor + 1 }
                if cursor + 1 < count, bytes[cursor] == UInt8(ascii: "-"), bytes[cursor + 1] == UInt8(ascii: ">") { return cursor + 2 }
                while cursor + 2 < count {
                    if bytes[cursor] == UInt8(ascii: "-"), bytes[cursor + 1] == UInt8(ascii: "-") {
                        if bytes[cursor + 2] == UInt8(ascii: ">") { return cursor + 3 }
                        if bytes[cursor + 2] == UInt8(ascii: "!"), cursor + 3 < count, bytes[cursor + 3] == UInt8(ascii: ">") {
                            return cursor + 4
                        }
                    }
                    cursor += 1
                }
                return count
            }
            return afterNext(UInt8(ascii: ">"), from: start)
        }

        func afterNext(_ byte: UInt8, from start: Int) -> Int {
            var cursor = start
            while cursor < count, bytes[cursor] != byte { cursor += 1 }
            return min(cursor + 1, count)
        }

        func readName(_ cursor: inout Int) -> String {
            let start = cursor
            while cursor < count, !isSpace(bytes[cursor]), bytes[cursor] != UInt8(ascii: "/"), bytes[cursor] != UInt8(ascii: ">") {
                cursor += 1
            }
            return lowered(start, cursor)
        }

        /// Reads attributes up to and including the closing `>`; returns the index after it.
        func readAttributes(from start: Int, into attributes: inout [HTMLAttribute], selfClosing: inout Bool) -> Int {
            var cursor = start
            while true {
                while cursor < count, isSpace(bytes[cursor]) { cursor += 1 }
                guard cursor < count else { return count }
                let byte = bytes[cursor]
                if byte == UInt8(ascii: ">") { return cursor + 1 }
                if byte == UInt8(ascii: "/") {
                    if cursor + 1 < count, bytes[cursor + 1] == UInt8(ascii: ">") {
                        selfClosing = true
                        return cursor + 2
                    }
                    cursor += 1
                    continue
                }
                let nameStart = cursor
                cursor += 1
                while cursor < count, !isSpace(bytes[cursor]), bytes[cursor] != UInt8(ascii: "/"),
                      bytes[cursor] != UInt8(ascii: ">"), bytes[cursor] != UInt8(ascii: "=") {
                    cursor += 1
                }
                let name = lowered(nameStart, cursor)
                while cursor < count, isSpace(bytes[cursor]) { cursor += 1 }
                var value = ""
                if cursor < count, bytes[cursor] == UInt8(ascii: "=") {
                    cursor += 1
                    while cursor < count, isSpace(bytes[cursor]) { cursor += 1 }
                    if cursor < count, bytes[cursor] == UInt8(ascii: "\"") || bytes[cursor] == UInt8(ascii: "'") {
                        let quote = bytes[cursor]
                        let valueStart = cursor + 1
                        var valueEnd = valueStart
                        while valueEnd < count, bytes[valueEnd] != quote { valueEnd += 1 }
                        value = string(valueStart, valueEnd)
                        cursor = min(valueEnd + 1, count)
                    } else {
                        let valueStart = cursor
                        while cursor < count, !isSpace(bytes[cursor]), bytes[cursor] != UInt8(ascii: ">") { cursor += 1 }
                        value = string(valueStart, cursor)
                    }
                }
                if !attributes.contains(where: { $0.name == name }) {
                    attributes.append(HTMLAttribute(name: name, value: HTMLEntities.decode(value)))
                }
            }
        }

        func string(_ start: Int, _ end: Int) -> String {
            String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<end]), as: UTF8.self)
        }

        func lowered(_ start: Int, _ end: Int) -> String {
            var copy = Array(bytes[start..<end])
            for index in copy.indices { copy[index] = lower(copy[index]) }
            return String(decoding: copy, as: UTF8.self)
        }

        func lower(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
        func isAlpha(_ byte: UInt8) -> Bool { (byte >= 65 && byte <= 90) || (byte >= 97 && byte <= 122) }
        func isSpace(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0C || byte == 0x0D }
    }
}
