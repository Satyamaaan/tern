#if DEBUG
import AppKit

/// The end-to-end update test can't click. Debug builds read `TERN_UPDATE_TEST`, a comma-separated list:
/// `check` runs "Check for Updates…" two seconds after launch, `restart` presses "Restart to update" once the ready
/// card is up, `quit` presses "Later" there and quits Tern. Every phase the card shows is logged.
@MainActor
enum UpdateTestHook {
    private static let steps = Set((ProcessInfo.processInfo.environment["TERN_UPDATE_TEST"] ?? "")
        .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

    static func started(_ updater: Updater) {
        guard steps.contains("check") else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { updater.checkForUpdates() }
        }
    }

    static func showed(_ phase: UpdatePhase, _ model: UpdateCardModel) {
        guard !steps.isEmpty else { return }
        NSLog("Tern update test: card shows \(phase)")
        guard case .ready = phase else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                guard case .ready = model.phase else { return }
                if steps.contains("restart") {
                    model.primary()
                } else if steps.contains("quit") {
                    model.secondary()
                    NSApp.terminate(nil)
                }
            }
        }
    }
}
#endif
