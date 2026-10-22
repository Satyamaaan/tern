import SwiftUI
import TernCore

/// What the list shows with nothing in it: the tern for inbox zero, one quiet line elsewhere.
struct EmptyListView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.isSeeding {
                EmptyLine(text: "Setting up the demo mailbox…")
            } else if model.isSearching {
                EmptyLine(text: "Nothing matches “\(model.searchText.trimmingCharacters(in: .whitespaces))”.")
            } else if model.kind == .waitingOn || model.kind == .iOwe {
                VStack(spacing: 10) {
                    Text(model.kind == .waitingOn ? "Unanswered requests you send will appear here." : "Promises you make will appear here.")
                        .font(.display(17)).foregroundStyle(Color(Theme.text2))
                    Text("Tern checks recent mail in the background. Only clear commitments appear here.")
                        .font(.ui(12)).foregroundStyle(Color(Theme.text3))
                }
                .multilineTextAlignment(.center).padding(32).padding(.bottom, 60)
            } else if case .inbox = model.kind, model.inboxTab == nil || model.inboxTab == .primary {
                InboxZeroView(cleared: model.prefs.clearedToday, drawn: model.emptiedByTriage && !reduceMotion)
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

/// Inbox zero: "Nothing needs you." and today's tally under the tern. Right after triage empties the list
/// (`drawn`) it arrives in sequence: the view fades in over the end of the collapse, the tern draws as one stroke
/// (900 ms), then the text rises in. Otherwise (opening an empty inbox, Reduce Motion) it is simply there.
struct InboxZeroView: View {
    let cleared: Int
    let drawn: Bool
    @State private var progress: CGFloat
    @State private var textShown: Bool

    /// The view's fade in, overlapping the last of the collapse.
    static let arrival = Animation.easeOut(duration: 0.2).delay(0.12)

    init(cleared: Int, drawn: Bool = false) {
        self.cleared = cleared
        self.drawn = drawn
        _progress = State(initialValue: drawn ? 0 : 1)
        _textShown = State(initialValue: !drawn)
    }

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
            .opacity(textShown ? 1 : 0)
            .offset(y: textShown ? 0 : 4)
        }
        .padding(.bottom, 60)
        .onAppear {
            guard drawn else { return }
            withAnimation(.easeInOut(duration: 0.9).delay(0.12)) { progress = 1 }
            withAnimation(.easeOut(duration: 0.3).delay(0.5)) { textShown = true }
        }
    }
}
