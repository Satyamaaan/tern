import Foundation

/// Reads JSON out of a model answer, repairing the usual damage: code fences, prose around the
/// object, trailing commas, and output cut off mid-array.
enum ModelJSON {
    /// The parsed object or array, or nil when nothing usable is in `text`.
    static func parse(_ text: String) -> Any? {
        let candidate = extract(text)
        if let value = decode(candidate) { return value }
        let cleaned = removeTrailingCommas(candidate)
        if let value = decode(cleaned) { return value }
        return salvageTruncated(cleaned)
    }

    /// From the first `{` or `[` to the last matching closer, without code fences.
    static func extract(_ text: String) -> String {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("```") {
            body = body.split(separator: "\n", omittingEmptySubsequences: false).dropFirst()
                .joined(separator: "\n")
            if let fence = body.range(of: "```", options: .backwards) { body = String(body[..<fence.lowerBound]) }
        }
        guard let start = body.firstIndex(where: { $0 == "{" || $0 == "[" }) else { return body }
        let closer: Character = body[start] == "{" ? "}" : "]"
        guard let end = body.lastIndex(of: closer), end > start else { return String(body[start...]) }
        return String(body[start...end])
    }

    static func removeTrailingCommas(_ text: String) -> String {
        text.replacingOccurrences(of: #",(\s*[}\]])"#, with: "$1", options: .regularExpression)
    }

    /// For output cut off mid-way: keep everything up to the last complete value and close what is open.
    static func salvageTruncated(_ text: String) -> Any? {
        let characters = Array(text)
        var stack: [Character] = []
        var inString = false
        var escaped = false
        // Positions just after a complete value inside a container, with the closers needed there.
        var cutPoints: [(index: Int, closers: [Character])] = []
        for (index, character) in characters.enumerated() {
            if inString {
                if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{": stack.append("}")
            case "[": stack.append("]")
            case "}", "]":
                guard !stack.isEmpty else { return nil }
                stack.removeLast()
                if !stack.isEmpty { cutPoints.append((index + 1, stack.reversed())) }
            default: break
            }
        }
        for point in cutPoints.reversed().prefix(50) {
            let repaired = String(characters[..<point.index]) + String(point.closers)
            if let value = decode(removeTrailingCommas(repaired)) { return value }
        }
        return nil
    }

    private static func decode(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
}

/// Lenient readers for values a model may type loosely ("true", "2", 2.0).
enum Loose {
    static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String: string
        case let number as NSNumber: number.stringValue
        default: nil
        }
    }

    static func bool(_ value: Any?) -> Bool? {
        switch value {
        case let bool as Bool: bool
        case let number as NSNumber: number.intValue != 0
        case let string as String: ["true", "yes", "1", "y"].contains(string.lowercased()) ? true
            : ["false", "no", "0", "n"].contains(string.lowercased()) ? false : nil
        default: nil
        }
    }

    static func int(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: Int(number.doubleValue.rounded())
        case let string as String: Int(string.trimmingCharacters(in: .whitespaces)) ?? Double(string).map { Int($0.rounded()) }
        default: nil
        }
    }
}
