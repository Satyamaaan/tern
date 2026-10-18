import AppKit
import Observation
import Sparkle

/// Tern's auto-update, on Sparkle 2 with Tern's own card instead of Sparkle's windows. Release builds only (see
/// `ReleaseBuild`): Sparkle checks the feed daily, downloads a new version in the background, and the card shows
/// once when it is ready. "Later" leaves it to install when Tern quits. "Check for Updates…" (menu, ⌘K,
/// Settings) runs a check the card shows step by step.
///
/// Sparkle does the parts that must not go wrong: the download, the EdDSA and code-signature checks against the
/// public key in Info.plist, and replacing the running app and opening the new one.
@MainActor
@Observable
final class Updater {
    @ObservationIgnored private var sparkle: SPUUpdater?
    @ObservationIgnored private let delegate = UpdaterDelegate()
    @ObservationIgnored private var driver: UpdateUserDriver?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    /// A version downloaded in the background that installs when Tern quits, and the way to install it now.
    private var pending: (release: UpdateRelease, install: () -> Void)?
    let window: UpdateWindow
    let version: AppVersion

    /// Download new versions in the background (Sparkle's automatic updates); they install when Tern restarts.
    /// When off, Tern still checks daily and asks before downloading.
    var automaticallyUpdates: Bool {
        didSet { sparkle?.automaticallyDownloadsUpdates = automaticallyUpdates }
    }
    /// Sparkle's `canCheckForUpdates`: false while a check or download is under way.
    private var sparkleCanCheck: Bool
    private(set) var lastChecked: Date?

    /// Whether "Check for Updates…" does something now. With a version waiting it shows that version again,
    /// even though Sparkle holds its own checks until Tern quits.
    var canCheck: Bool { pending != nil || sparkleCanCheck }

    private init(window: UpdateWindow, version: AppVersion, automaticallyUpdates: Bool, sparkleCanCheck: Bool, lastChecked: Date?) {
        self.window = window
        self.version = version
        self.automaticallyUpdates = automaticallyUpdates
        self.sparkleCanCheck = sparkleCanCheck
        self.lastChecked = lastChecked
    }

    /// Starts updating in a release build. Nil in development builds and offscreen runs (`--check`,
    /// `--snapshot`); tests never get here.
    static func start(options: LaunchOptions, location: AppLocation) -> Updater? {
        guard ReleaseBuild.isCurrent, !options.isHeadless else { return nil }
        let window = UpdateWindow()
        let driver = UpdateUserDriver(window: window)
        let updater = Updater(window: window, version: .current, automaticallyUpdates: true, sparkleCanCheck: false, lastChecked: nil)
        let sparkle = SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: updater.delegate)
        // A copy on a disk image or translocated by Gatekeeper is read-only: Sparkle couldn't replace it, so
        // only checks the user asks for run (and explain why).
        updater.delegate.skipsBackgroundChecks = location.isReadOnly
        updater.delegate.readyOnQuit = { [weak updater] item, install in updater?.readyOnQuit(item, install: install) }
        updater.delegate.cycleFinished = { [weak updater, weak sparkle] in updater?.lastChecked = sparkle?.lastUpdateCheckDate }
        do {
            try sparkle.start()
        } catch {
            NSLog("Tern: the updater didn't start: \(error)")
            return nil
        }
        updater.sparkle = sparkle
        updater.driver = driver
        updater.automaticallyUpdates = sparkle.automaticallyDownloadsUpdates
        updater.lastChecked = sparkle.lastUpdateCheckDate
        updater.observation = sparkle.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak updater] sparkle, _ in
            let canCheck = sparkle.canCheckForUpdates
            DispatchQueue.main.async { MainActor.assumeIsolated { updater?.sparkleCanCheck = canCheck } }
        }
        #if DEBUG
        UpdateTestHook.started(updater)
        #endif
        return updater
    }

    /// Settings and the update card as a release build shows them, without Sparkle (snapshots).
    static func preview(automaticallyUpdates: Bool = true, lastChecked: Date? = Date().addingTimeInterval(-3 * 3600)) -> Updater {
        Updater(window: UpdateWindow(), version: AppVersion(name: "0.2.0", build: "2"),
                automaticallyUpdates: automaticallyUpdates, sparkleCanCheck: true, lastChecked: lastChecked)
    }

    /// "Check for Updates…". With a version already downloaded, shows it again instead of checking.
    func checkForUpdates() {
        if let pending {
            showReady(pending.release, focus: true, install: pending.install)
        } else if let sparkle, sparkle.canCheckForUpdates {
            sparkle.checkForUpdates()
        } else {
            window.focus()
        }
    }

    /// A background download finished; Sparkle installs it when Tern quits unless "Restart to update" says now.
    private func readyOnQuit(_ item: SUAppcastItem, install: @escaping () -> Void) {
        let release = UpdateRelease(item: item)
        pending = (release, install)
        // It arrives on its own, maybe while the user types: shown, but without the keyboard.
        showReady(release, focus: false, install: install)
    }

    private func showReady(_ release: UpdateRelease, focus: Bool, install: @escaping () -> Void) {
        window.show(.ready(release), focus: focus, primary: { [weak self] in
            self?.window.show(.installing(release, waitingToQuit: false), focus: true)
            install()
        }, secondary: { [weak self] in
            self?.window.close()
        })
    }
}

/// Sparkle's delegate: hands background downloads that are ready to `Updater`, keeps background checks off a
/// read-only copy, and notes when a check finished.
@MainActor
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var readyOnQuit: ((SUAppcastItem, @escaping () -> Void) -> Void)?
    var cycleFinished: (() -> Void)?
    var skipsBackgroundChecks = false

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        guard let readyOnQuit else { return false }
        // Taking it over: Sparkle stops its own reminders and the card offers "Restart to update" once.
        readyOnQuit(item, immediateInstallationBlock)
        return true
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        if skipsBackgroundChecks, updateCheck == .updatesInBackground {
            throw NSError(domain: SUSparkleErrorDomain, code: Int(SUError.runningFromDiskImageError.rawValue))
        }
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        cycleFinished?()
    }
}
