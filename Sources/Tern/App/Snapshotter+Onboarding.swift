import AppKit
import SwiftUI

// Onboarding's Accounts, AI and Done steps, with made-up CLI statuses: the real CLIs never run in snapshots.
extension Snapshotter {
    func onboardingShots(_ directory: URL) {
        let services = model.services
        let availability = services.aiAvailability
        let size = NSSize(width: 640, height: 560)
        func onboarding(_ name: String, step: Int) {
            for dark in [false, true] {
                standalone(OnboardingView(onFinish: {}, onDemo: {}, startStep: step).environment(model).environment(services), size: size,
                           to: directory.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png"), dark: dark)
            }
        }

        onboarding("onboarding-accounts", step: 1)
        let states: [(name: String, claude: AIStatus, codex: AIStatus)] = [
            ("ready", .ready, .ready), ("signedout", .signedOut, .signedOut),
            ("notinstalled", .notInstalled, .notInstalled), ("mixed", .signedOut, .ready),
        ]
        for state in states {
            services.aiAvailability = Self.fakeAvailability(claude: state.claude, codex: state.codex)
            onboarding("onboarding-ai-\(state.name)", step: 2)
        }
        services.aiAvailability = Self.fakeAvailability(claude: .ready, codex: .signedOut)
        onboarding("onboarding-done", step: 3)

        services.aiAvailability = availability
    }

    /// Answers at once with the given statuses.
    static func fakeAvailability(claude: AIStatus, codex: AIStatus) -> AIAvailabilityCheck {
        { provider, _ in provider == .claude ? claude : provider == .codex ? codex : .notInstalled }
    }
}
