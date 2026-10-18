import Foundation
import TernCore

/// Command-line arguments and environment the app reads at launch.
///
/// - `TERN_DB=/path` opens that database file.
/// - `--fake` or `TERN_FAKE=1` opens the demo mailbox (`Tern-Fake.sqlite`), seeding it if empty.
/// - `--snapshot <dir>` renders the main window offscreen into PNGs and quits.
/// - `--check` drives the shell offscreen through its behaviour and quits.
struct LaunchOptions {
    var databaseURL: URL
    var isFake: Bool
    var snapshotDirectory: URL?
    var isCheck = false

    /// Offscreen runs (`--snapshot`, `--check`): no updater, no prompts, nothing on screen.
    var isHeadless: Bool { snapshotDirectory != nil || isCheck }

    static func current(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> LaunchOptions {
        let isFake = arguments.contains("--fake") || environment["TERN_FAKE"] == "1"
        let url: URL
        if let path = environment["TERN_DB"], !path.isEmpty {
            url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        } else {
            url = AppDatabase.defaultURL(name: isFake ? "Tern-Fake" : "Tern")
        }
        var snapshot: URL?
        if let index = arguments.firstIndex(of: "--snapshot"), index + 1 < arguments.count {
            snapshot = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
        }
        return LaunchOptions(databaseURL: url, isFake: isFake, snapshotDirectory: snapshot, isCheck: arguments.contains("--check"))
    }
}
