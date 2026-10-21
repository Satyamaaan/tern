import SwiftUI

/// Onboarding's AI step: Claude Code and Codex as cards with their live status, then "Skip, no AI".
/// The arrow keys move the choice.
struct OnboardingAIStep: View {
    let board: AIStatusBoard
    let choice: AIProvider?
    let choose: (AIProvider) -> Void
    let recheck: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(AIProvider.tools) { provider in
                    AIProviderCard(provider: provider, status: board.statuses[provider], isChecking: board.isChecking, selected: choice == provider) {
                        choose(provider)
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 10) {
                Button { choose(.off) } label: {
                    HStack(spacing: 10) {
                        RadioMark(selected: choice == .off)
                        Text("Skip, no AI").font(.ui(13)).foregroundStyle(Color(Theme.text1))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 17)
                Spacer()
                if board.needsAttention {
                    Button(action: recheck) {
                        HStack(spacing: 6) {
                            IconView(icon: .refresh, size: 13, color: Color(Theme.text2))
                            Text(board.isChecking ? "Checking…" : "Check again")
                        }
                    }
                    .buttonStyle(TernButtonStyle(.quiet, size: .small))
                    .disabled(board.isChecking)
                }
            }
            .frame(height: 28)
            .padding(.top, 12)

            Text("The text each feature needs goes to that provider through your own sign-in. Tern has no servers.")
                .font(.ui(12))
                .foregroundStyle(Color(Theme.text3))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
        }
        // The arrow keys go to an empty focus target behind the step: a focusable container would mark
        // every button inside it as focused.
        .background(
            Color.clear
                .focusable()
                .focusEffectDisabled()
                .focused($focused)
                .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
                    move(press.key == .leftArrow || press.key == .upArrow ? -1 : 1)
                    return .handled
                })
        .onAppear { focused = true }
    }

    private func move(_ step: Int) {
        let options = AIProvider.tools + [.off]
        let index = choice.flatMap { options.firstIndex(of: $0) } ?? (step > 0 ? -1 : options.count)
        choose(options[min(max(index + step, 0), options.count - 1)])
    }
}
