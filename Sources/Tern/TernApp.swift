import SwiftUI
import TernCore

// Placeholder shell so the package builds; the UI lane replaces this.
@main
struct TernApp: App {
    let store: MailStore? = {
        let fake = CommandLine.arguments.contains("--fake") || ProcessInfo.processInfo.environment["TERN_FAKE"] == "1"
        let url = AppDatabase.defaultURL(name: fake ? "Tern-Fake" : "Tern")
        return (try? AppDatabase.open(at: url)).map(MailStore.init)
    }()

    var body: some Scene {
        WindowGroup("Tern") {
            List((try? store?.threadRows(in: .unifiedInbox)) ?? []) { row in
                VStack(alignment: .leading) {
                    Text(row.thread.participants.first?.displayName ?? "").bold()
                    Text(row.thread.subject)
                }
            }
            .frame(minWidth: 600, minHeight: 400)
        }
    }
}
