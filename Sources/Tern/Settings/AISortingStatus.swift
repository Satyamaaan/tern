import SwiftUI
import TernAI

/// What AI sorting (`TriageQueue`) is doing, as Settings → AI shows it.
struct AISorting: Hashable {
    var status: TriageQueue.Status

    /// Nothing to show while AI is off.
    var isShown: Bool { status.state != .off }

    /// One quiet line: "Sorting 120 of 800", "Up to date", "Paused until 14:05".
    func line(now: Date = Date()) -> String {
        switch status.state {
        case .off: "Off"
        case .idle: "Up to date"
        case .working:
            if let progress = status.progress, progress.total > 0 {
                "Sorting \(Self.number(min(progress.done, progress.total))) of \(Self.number(progress.total))"
            } else {
                "Sorting"
            }
        case .waiting(let until, _):
            until > now ? "Paused until \(until.formatted(date: .omitted, time: .shortened))" : "Resuming"
        case .unavailable: "Waiting for the tool"
        }
    }

    /// Why it paused, when it did.
    var reason: String? {
        switch status.state {
        case .waiting(_, let reason): reason.isEmpty ? nil : reason
        case .unavailable(let message): message
        default: nil
        }
    }

    private static func number(_ value: Int) -> String {
        value.formatted(.number.grouping(.automatic))
    }
}

/// Settings → AI: the sorting line, in plain text.
struct AISortingItem: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        if let sorting = services.aiSorting {
            SettingsRow(title: "Sorting", detail: sorting.reason ?? "New mail is sorted with AI after the instant rules.") {
                Text(sorting.line())
                    .font(.numeric(12))
                    .foregroundStyle(Color(Theme.text2))
            }
        }
    }
}
