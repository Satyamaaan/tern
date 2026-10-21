import Foundation
import TernCore

/// One line in the message list.
enum ListItem: Hashable {
    /// A sticky date header, e.g. "Today".
    case header(String)
    case thread(ThreadKey)
    /// The quiet last row of search results that asks Gmail for older mail, with its current text.
    case serverSearch(String)

    var threadKey: ThreadKey? {
        if case .thread(let key) = self { return key }
        return nil
    }
}

/// The list as displayed: rows in order plus date headers, with lookups for keyboard movement.
struct ListSnapshot {
    private(set) var items: [ListItem] = []
    private(set) var rows: [ThreadKey: ThreadRow] = [:]
    /// Thread keys in display order.
    private(set) var order: [ThreadKey] = []
    private(set) var position: [ThreadKey: Int] = [:]
    private(set) var itemIndex: [ThreadKey: Int] = [:]
    /// The category most of the list shares (more than half, of eight or more threads). Its tag would
    /// repeat on nearly every row and say nothing, so rows leave it off.
    private(set) var commonCategory: MailCategory?

    static let empty = ListSnapshot()

    init() {}

    init(rows input: [ThreadRow], groupsByDate: Bool, footer: ListItem? = nil, now: Date = Date(), calendar: Calendar = .current) {
        let rest = input[...]
        if groupsByDate {
            let buckets = DateBuckets(now: now, calendar: calendar)
            var emitted = Set<String>()
            var current: String?
            for row in rest {
                let title = buckets.title(for: row.thread.lastDate)
                if title != current, emitted.insert(title).inserted {
                    items.append(.header(title))
                    current = title
                }
                append(row)
            }
        } else {
            for row in rest { append(row) }
        }
        if let footer { items.append(footer) }
        commonCategory = Self.common(rows.values.compactMap(\.category), of: order.count)
    }

    private static func common(_ categories: [MailCategory], of total: Int) -> MailCategory? {
        guard total >= 8 else { return nil }
        let counts = Dictionary(categories.map { ($0, 1) }, uniquingKeysWith: +)
        guard let top = counts.max(by: { $0.value < $1.value }), top.value * 2 > total else { return nil }
        return top.key
    }

    private mutating func append(_ row: ThreadRow) {
        guard rows[row.id] == nil else { return }
        rows[row.id] = row
        position[row.id] = order.count
        order.append(row.id)
        itemIndex[row.id] = items.count
        items.append(.thread(row.id))
    }

    var isEmpty: Bool { order.isEmpty }

    func row(at itemIndex: Int) -> ThreadRow? {
        guard items.indices.contains(itemIndex), case .thread(let key) = items[itemIndex] else { return nil }
        return rows[key]
    }

    /// The thread `offset` steps from `key`, clamped to the list.
    func key(from key: ThreadKey?, offset: Int) -> ThreadKey? {
        guard !order.isEmpty else { return nil }
        guard let key, let index = position[key] else { return offset >= 0 ? order.first : order.last }
        return order[min(max(index + offset, 0), order.count - 1)]
    }

    /// Thread keys between two keys, inclusive, in display order.
    func range(from a: ThreadKey, to b: ThreadKey) -> [ThreadKey] {
        guard let i = position[a], let j = position[b] else { return [b] }
        return Array(order[min(i, j)...max(i, j)])
    }
}

/// Titles for date groups: Today, Yesterday, This week, Earlier this month, month names, years.
struct DateBuckets {
    let today: Date
    let yesterday: Date
    let week: Date
    let month: Date
    let year: Date
    let calendar: Calendar
    private let monthNames: [String]

    init(now: Date, calendar: Calendar) {
        self.calendar = calendar
        today = calendar.startOfDay(for: now)
        yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? yesterday
        month = calendar.dateInterval(of: .month, for: now)?.start ?? week
        year = calendar.dateInterval(of: .year, for: now)?.start ?? month
        monthNames = calendar.standaloneMonthSymbols.map(\.localizedCapitalized)
    }

    func title(for date: Date) -> String {
        if date >= today { return "Today" }
        if date >= yesterday { return "Yesterday" }
        if date >= week { return "This week" }
        if date >= month { return "Earlier this month" }
        if date >= year { return monthNames[calendar.component(.month, from: date) - 1] }
        return String(calendar.component(.year, from: date))
    }
}
