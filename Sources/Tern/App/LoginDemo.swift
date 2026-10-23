#if DEBUG
import Foundation
import TernCore

/// Debug builds on the demo mailbox: `TERN_DEMO_LOGIN=<seconds>` delivers one sign-in email that many seconds after
/// launch, so the login popup can be seen arriving while another app is in front.
enum LoginDemo {
    @MainActor static func schedule(_ services: AppServices, environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let delay = environment["TERN_DEMO_LOGIN"].flatMap(Double.init), delay >= 0 else { return }
        let store = services.store
        Task.detached {
            try? await Task.sleep(for: .seconds(delay))
            guard let account = (try? store.accounts())?.first?.id else { return }
            let stamp = Int(Date().timeIntervalSince1970)
            let message = MailMessage(
                accountId: account, id: "demo-login-\(stamp)", threadId: "demo-login-\(stamp)", date: Date(),
                fromName: "Linear", fromEmail: "noreply@linear.app", toList: [Participant(email: account)],
                subject: "Your Linear sign-in code", snippet: "Your Linear verification code is: 482 913",
                bodyText: """
                    Your Linear verification code is: 482 913

                    Or sign in to Linear with this magic link: https://linear.app/auth/magic/Zk3P9qLmA7xR2vT8wBn5

                    This code expires in 10 minutes.
                    """,
                bodyState: .full, labelIds: [SystemLabel.inbox, SystemLabel.unread, "CATEGORY_UPDATES"])
            try? store.upsertMessages([message])
        }
    }
}
#endif
