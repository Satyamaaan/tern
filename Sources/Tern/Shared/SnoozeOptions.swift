import Foundation
import SwiftUI
import TernCore

/// Snooze presets shared by the list, the reader and the palette.
struct SnoozeOption: Identifiable, Hashable {
    let id: String
    let title: String
    /// Short time shown at the right of the menu row, e.g. "Tue 8:00".
    let detail: String
    let date: Date

    /// Later today (+3 h, rounded to the hour) · Tomorrow 8:00 · This weekend (Sat 9:00) · Next week (Mon 8:00).
    /// Options that would land in the past or duplicate an earlier one are dropped.
    static func presets(now: Date = Date(), calendar: Calendar = .current) -> [SnoozeOption] {
        var options: [SnoozeOption] = []
        func add(_ id: String, _ title: String, _ date: Date?) {
            guard let date, date > now, !options.contains(where: { abs($0.date.timeIntervalSince(date)) < 60 }) else { return }
            options.append(SnoozeOption(id: id, title: title, detail: detailText(date, now: now, calendar: calendar), date: date))
        }

        let laterToday = calendar.date(byAdding: .hour, value: 3, to: now).flatMap {
            calendar.date(bySetting: .minute, value: 0, of: $0)
        }
        if let laterToday, calendar.isDate(laterToday, inSameDayAs: now), calendar.component(.hour, from: laterToday) < 21 {
            add("later", "Later today", laterToday)
        }
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
            .flatMap { calendar.date(bySettingHour: 8, minute: 0, second: 0, of: $0) }
        add("tomorrow", "Tomorrow", tomorrow)
        let saturday = calendar.nextDate(after: now, matching: DateComponents(hour: 9, minute: 0, weekday: 7), matchingPolicy: .nextTime)
        add("weekend", "This weekend", saturday)
        let monday = calendar.nextDate(after: now, matching: DateComponents(hour: 8, minute: 0, weekday: 2), matchingPolicy: .nextTime)
        add("nextWeek", "Next week", monday)
        return options
    }

    static func detailText(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return time }
        if let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: date).day, days < 7 {
            return "\(date.formatted(.dateTime.weekday(.abbreviated))) \(time)"
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Menu content listing the presets plus "Pick date…". Put it inside a `Menu`.
struct SnoozeMenuItems: View {
    let threads: [ThreadKey]
    var onPickDate: () -> Void = {}

    @Environment(AppServices.self) private var services

    var body: some View {
        ForEach(SnoozeOption.presets()) { option in
            Button("\(option.title)  —  \(option.detail)") {
                services.perform(.snooze(until: option.date), threads)
            }
        }
        Divider()
        Button("Pick date…", action: onPickDate)
    }
}
