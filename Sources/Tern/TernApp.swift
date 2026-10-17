import SwiftUI
import TernCore

// Placeholder shell so the package builds; the UI shell lane replaces this.
@main
struct TernApp: App {
    @State private var services: AppServices? = {
        Theme.registerFonts()
        let fake = CommandLine.arguments.contains("--fake") || ProcessInfo.processInfo.environment["TERN_FAKE"] == "1"
        let url = AppDatabase.defaultURL(name: fake ? "Tern-Fake" : "Tern")
        return (try? AppDatabase.open(at: url)).map { AppServices(store: MailStore($0)) }
    }()

    var body: some Scene {
        WindowGroup("Tern") {
            if let services {
                HSplitView {
                    List((try? services.store.threadRows(in: .unifiedInbox)) ?? []) { row in
                        VStack(alignment: .leading) {
                            Text(row.thread.participants.first?.displayName ?? "").font(.ui(13, .semibold))
                            Text(row.thread.subject).font(.ui(13))
                        }
                    }
                    ReaderView(key: nil)
                }
                .environment(services)
                .frame(minWidth: 900, minHeight: 560)
            }
        }
    }
}
