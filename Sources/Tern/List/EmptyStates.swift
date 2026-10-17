import SwiftUI
import TernCore

/// What the list shows with nothing in it: the tern for inbox zero, one serif line elsewhere.
struct EmptyListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isSeeding {
                SerifLine(text: "Setting up the demo mailbox…")
            } else if model.isSearching {
                SerifLine(text: "Nothing matches “\(model.searchText.trimmingCharacters(in: .whitespaces))”.")
            } else if case .inbox = model.kind {
                InboxZeroView(cleared: model.prefs.clearedToday)
            } else {
                SerifLine(text: model.kind.emptyLine)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SerifLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.serif(22, italic: true))
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
                    .font(.serif(22, italic: true))
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

/// The tern in flight as a single continuous stroke: forked tail, slim body, raised swept wing,
/// capped head and a long pointed beak. Drawn in a 132 × 66 box.
struct TernMark: Shape {
    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 132, sy = rect.height / 66
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        // Lower tail streamer, up into the fork and along the belly.
        path.move(to: p(4, 50))
        path.addQuadCurve(to: p(30, 38), control: p(18, 41))
        path.addCurve(to: p(84, 40), control1: p(48, 44), control2: p(70, 45))
        // Throat to the beak tip, back along the upper bill to the forehead.
        path.addCurve(to: p(103, 31), control1: p(93, 37), control2: p(98, 33))
        path.addLine(to: p(128, 29))
        path.addLine(to: p(103, 26))
        // The black cap over the crown to the nape.
        path.addCurve(to: p(88, 24), control1: p(98, 21), control2: p(92, 21))
        // Leading edge of the raised wing to the wrist and out to the tip.
        path.addCurve(to: p(66, 22), control1: p(80, 24), control2: p(72, 24))
        path.addCurve(to: p(48, 6), control1: p(60, 18), control2: p(54, 10))
        path.addLine(to: p(20, 2))
        // Trailing edge back to the body.
        path.addCurve(to: p(56, 30), control1: p(34, 10), control2: p(46, 26))
        // Back to the tail and out to the upper streamer.
        path.addCurve(to: p(30, 33), control1: p(46, 32), control2: p(38, 33))
        path.addQuadCurve(to: p(2, 32), control: p(16, 30))
        return path
    }
}
