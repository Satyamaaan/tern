import Foundation
import TernCore

/// Text shown in list rows: senders and compact times.
enum RowFormat {
    /// "17m", "3h", "Tue", "Oct 12", "Oct 12 '25".
    static func compactTime(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 {
            // Slightly in the future (clock skew, scheduled mail): "now" today, the date otherwise.
            return calendar.isDate(date, inSameDayAs: now) || seconds > -60 ? "now" : dayMonth.string(from: date)
        }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if calendar.isDate(date, inSameDayAs: now) { return "\(Int(seconds / 3600))h" }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if days < 7 { return weekday.string(from: date) }
        if calendar.component(.year, from: date) == calendar.component(.year, from: now) {
            return dayMonth.string(from: date)
        }
        return dayMonthYear.string(from: date)
    }

    /// Who the row names: "Maya Chen", "Jonas, Priya, me", "me". Count is the message count when > 1.
    static func senders(_ thread: MailThread) -> (text: String, count: Int?) {
        let me = thread.accountId
        let people = thread.participants
        let count = thread.messageCount > 1 ? thread.messageCount : nil
        let others = people.filter { $0.email.lowercased() != me }
        if others.count == 1, people.count == 1 { return (others[0].displayName, count) }
        if others.isEmpty { return ("me", count) }
        var names = others.prefix(3).map(\.firstName)
        if people.count > others.count, names.count < 3 { names.append("me") }
        return (names.joined(separator: ", "), count)
    }

    /// "Draft to Maya" for threads whose newest message is your unsent draft.
    static func draftLine(_ thread: MailThread) -> String? {
        guard thread.hasDraft else { return nil }
        let me = thread.accountId
        guard let other = thread.participants.last(where: { $0.email.lowercased() != me }) else { return "Draft" }
        return "Draft to \(other.firstName)"
    }

    private static let weekday = formatter("EEE")
    private static let dayMonth = formatter("MMM d")
    private static let dayMonthYear = formatter("MMM d ''yy")

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }
}
