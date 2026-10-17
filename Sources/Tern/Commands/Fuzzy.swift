import Foundation

/// Subsequence matching for the palette: "arc" finds "Archive", "mtp" finds "Move to Project".
/// Higher scores for matches at the start, at word starts and in runs.
enum Fuzzy {
    static func score(_ query: String, in text: String) -> Int? {
        let needle = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !needle.isEmpty else { return 0 }
        let haystack = Array(text.lowercased())
        var score = 0
        var index = 0
        var previous = -2
        for char in needle {
            guard let found = haystack[index...].firstIndex(of: char) else { return nil }
            let atWordStart = found == 0 || !haystack[found - 1].isLetter
            score += 1
            if found == previous + 1 { score += 5 }
            if atWordStart { score += 8 }
            if found == 0 { score += 10 }
            score -= min(found - index, 6)
            previous = found
            index = found + 1
        }
        return score - haystack.count / 8
    }

    /// Best score over a title and its aliases.
    static func best(_ query: String, title: String, aliases: [String] = []) -> Int? {
        ([title] + aliases).compactMap { score(query, in: $0) }.max()
    }
}
