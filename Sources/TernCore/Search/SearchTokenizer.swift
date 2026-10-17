import Foundation

/// Splits text the way the message index does (letters and digits are token characters, everything
/// else separates), so queries and highlights line up with what the index matched.
enum SearchTokenizer {
    static func isTokenCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func tokens(in text: String) -> [String] {
        var result: [String] = []
        var current = ""
        for character in text {
            if isTokenCharacter(character) {
                current.append(character)
            } else if !current.isEmpty {
                result.append(current)
                current = ""
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Case and diacritics folded, like the index's `unicode61 remove_diacritics` tokenizer.
    static func fold(_ token: String) -> String {
        if token.utf8.allSatisfy({ $0 < 0x80 }) { return token.lowercased() }
        return token.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    struct Token {
        var folded: String
        /// UTF-16 range in the source string.
        var range: NSRange
    }

    static func foldedTokens(in text: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var start = 0
        var offset = 0
        for character in text {
            let length = character.utf16.count
            if isTokenCharacter(character) {
                if current.isEmpty { start = offset }
                current.append(character)
            } else if !current.isEmpty {
                result.append(Token(folded: fold(current), range: NSRange(location: start, length: offset - start)))
                current = ""
            }
            offset += length
        }
        if !current.isEmpty {
            result.append(Token(folded: fold(current), range: NSRange(location: start, length: offset - start)))
        }
        return result
    }
}

/// Finds where the positive words and phrases of a query occur in a piece of text, for bold or
/// highlighted spans in the result list.
public struct SearchHighlighter: Sendable {
    struct Term: Hashable, Sendable {
        var tokens: [String]
        var isPrefix: Bool
    }

    /// A term whose words are all ASCII once folded, so it can be matched against ASCII text byte by byte.
    private struct ASCIITerm: Sendable {
        var words: [[UInt8]]
        var isPrefix: Bool
    }

    let terms: [Term]
    private let asciiTerms: [ASCIITerm]

    init(terms: [Term]) {
        self.terms = terms
        asciiTerms = terms.compactMap { term in
            let words = term.tokens.map { Array($0.utf8) }
            return words.allSatisfy({ $0.allSatisfy { $0 < 0x80 } }) ? ASCIITerm(words: words, isPrefix: term.isPrefix) : nil
        }
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// UTF-16 ranges (usable with `NSAttributedString`), sorted and merged.
    public func ranges(in text: String) -> [NSRange] {
        guard !terms.isEmpty, !text.isEmpty else { return [] }
        var text = text
        if let fast = text.withUTF8({ asciiRanges(in: $0) }) { return fast }
        return unicodeRanges(in: text)
    }

    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
    }

    /// Plain ASCII text (nearly every excerpt): scan bytes, no String work. Nil when the text has other characters.
    private func asciiRanges(in bytes: UnsafeBufferPointer<UInt8>) -> [NSRange]? {
        var starts: [Int] = []
        var ends: [Int] = []
        var i = 0
        let count = bytes.count
        while i < count {
            let byte = bytes[i]
            if byte >= 0x80 { return nil }
            if Self.isWordByte(byte) {
                let start = i
                i += 1
                while i < count, Self.isWordByte(bytes[i]) { i += 1 }
                starts.append(start)
                ends.append(i)
            } else {
                i += 1
            }
        }
        if i < count { return nil }
        guard !starts.isEmpty else { return [] }

        var found: [NSRange] = []
        for term in asciiTerms where term.words.count <= starts.count {
            let last = term.words.count - 1
            for first in 0...(starts.count - term.words.count) {
                var matches = true
                for offset in 0...last {
                    let word = term.words[offset]
                    let start = starts[first + offset]
                    let length = ends[first + offset] - start
                    let prefix = offset == last && term.isPrefix
                    if prefix ? length < word.count : length != word.count { matches = false; break }
                    for index in 0..<word.count where bytes[start + index] | 0x20 != word[index] { matches = false; break }
                    if !matches { break }
                }
                if matches {
                    found.append(NSRange(location: starts[first], length: ends[first + last] - starts[first]))
                }
            }
        }
        return Self.merge(found)
    }

    private func unicodeRanges(in text: String) -> [NSRange] {
        let tokens = SearchTokenizer.foldedTokens(in: text)
        guard !tokens.isEmpty else { return [] }
        var found: [NSRange] = []
        for term in terms where term.tokens.count <= tokens.count {
            let last = term.tokens.count - 1
            for start in 0...(tokens.count - term.tokens.count) {
                var matches = true
                for offset in 0...last {
                    let word = tokens[start + offset].folded
                    let expected = term.tokens[offset]
                    if offset == last && term.isPrefix ? !word.hasPrefix(expected) : word != expected {
                        matches = false
                        break
                    }
                }
                if matches {
                    let first = tokens[start].range
                    let end = tokens[start + last].range
                    found.append(NSRange(location: first.location, length: end.location + end.length - first.location))
                }
            }
        }
        return Self.merge(found)
    }

    static func merge(_ ranges: [NSRange]) -> [NSRange] {
        let sorted = ranges.sorted { $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let previous = merged.last, range.location <= previous.location + previous.length {
                let end = max(previous.location + previous.length, range.location + range.length)
                merged[merged.count - 1] = NSRange(location: previous.location, length: end - previous.location)
            } else {
                merged.append(range)
            }
        }
        return merged
    }
}
