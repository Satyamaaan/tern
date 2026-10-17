import Foundation
import TernCore

/// One line in the message list.
enum ListItem: Hashable {
    /// A sticky caps header, e.g. "TODAY".
    case header(String)
    /// The dashed line under the needs-reply group, with that group's size.
    case waterline(Int)
    case thread(ThreadKey)
    /// The quiet last row of search results that asks Gmail for older mail, with its current text.
    case serverSearch(String)

    var threadKey: ThreadKey? {
        if case .thread(let key) = self { return key }
        return nil
    }
}

/// The list as displayed: rows in order plus group headers, with lookups for keyboard movement.
struct ListSnapshot {
    private(set) var items: [ListItem] = []
    private(set) var rows: [ThreadKey: ThreadRow] = [:]
    /// Thread keys in display order.
    private(set) var order: [ThreadKey] = []
    private(set) var position: [ThreadKey: Int] = [:]
    private(set) var itemIndex: [ThreadKey: Int] = [:]
    /// Size of the needs-reply group at the top, if any.
    private(set) var needsReplyCount = 0

    static let empty = ListSnapshot()

    init() {}

    init(rows input: [ThreadRow], needsReplyFirst: Bool, groupsByDate: Bool, footer: ListItem? = nil,
         now: Date = Date(), calendar: Calendar = .current) {
        var waiting: ArraySlice<ThreadRow> = []
        var rest = input[...]
        if needsReplyFirst {
            let split = input.firstIndex(where: { !$0.needsReply }) ?? input.endIndex
            waiting = input[..<split]
            rest = input[split...]
        }

        if !waiting.isEmpty {
            items.append(.header("NEEDS REPLY"))
            for row in waiting { append(row) }
            needsReplyCount = waiting.count
            if !rest.isEmpty { items.append(.waterline(waiting.count)) }
        }

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

/// Caps titles for date groups: TODAY, YESTERDAY, THIS WEEK, EARLIER THIS MONTH, month names, years.
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
        monthNames = calendar.standaloneMonthSymbols.map { $0.uppercased() }
    }

    func title(for date: Date) -> String {
        if date >= today { return "TODAY" }
        if date >= yesterday { return "YESTERDAY" }
        if date >= week { return "THIS WEEK" }
        if date >= month { return "EARLIER THIS MONTH" }
        if date >= year { return monthNames[calendar.component(.month, from: date) - 1] }
        return String(calendar.component(.year, from: date))
    }
}
