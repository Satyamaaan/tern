import SwiftUI
import TernCore

/// What the list shows with nothing in it: the tern for inbox zero, one quiet line elsewhere.
struct EmptyListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isSeeding {
                EmptyLine(text: "Setting up the demo mailbox…")
            } else if model.isSearching {
                EmptyLine(text: "Nothing matches “\(model.searchText.trimmingCharacters(in: .whitespaces))”.")
            } else if case .inbox = model.kind, model.inboxTab == nil || model.inboxTab == .primary {
                InboxZeroView(cleared: model.prefs.clearedToday)
            } else if case .inbox = model.kind {
                EmptyLine(text: "Nothing in this tab.")
            } else {
                EmptyLine(text: model.kind.emptyLine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct EmptyLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.display(17))
            .tracking(-0.2)
            .foregroundStyle(Color(Theme.text2))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 32)
            .padding(.bottom, 60)
    }
}

/// Inbox zero: the tern drawn as one stroke (900 ms), "Nothing needs you." and today's tally.
struct InboxZeroView: View {
    let cleared: Int
    @State private var progress: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 18) {
            TernMark()
                .trim(from: 0, to: progress)
                .stroke(Color(Theme.text1), style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
                .frame(width: 132, height: 66)
            VStack(spacing: 6) {
                Text("Nothing needs you.")
                    .font(.display(20))
                    .tracking(-0.3)
                    .foregroundStyle(Color(Theme.text1))
                Text(cleared > 0 ? "\(cleared) cleared today" : "All caught up")
                    .font(.ui(12))
                    .foregroundStyle(Color(Theme.text3))
            }
        }
        .padding(.bottom, 60)
        .onAppear {
            if reduceMotion { progress = 1; return }
            withAnimation(.easeInOut(duration: 0.9)) { progress = 1 }
        }
    }
}
