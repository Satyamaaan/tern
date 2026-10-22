import Foundation
import TernCore

/// A cheap recall-oriented filter. Only fresh, unquoted message text is inspected.
enum CommitmentCues {
    private static let pattern = try! NSRegularExpression(pattern: #"\b(i['’]ll|i will|we['’]ll|we will|tomorrow|by end of|eod|next week|will send|will get you|can you|could you|would you|please (send|share|review|sign)|send me|need you to|by (monday|tuesday|wednesday|thursday|friday|saturday|sunday|eod|tomorrow|\d)|deadline|due|get back to you|follow up)\b"#, options: [.caseInsensitive])
    static func contains(_ text: String) -> Bool {
        let fresh = MailText.stripQuoted(text)
        return pattern.firstMatch(in: fresh, range: NSRange(fresh.startIndex..., in: fresh)) != nil
    }
}
