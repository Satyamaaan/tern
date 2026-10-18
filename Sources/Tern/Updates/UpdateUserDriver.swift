import AppKit
import Sparkle

/// Sparkle's user interface, drawn as Tern's update card instead of Sparkle's standard windows. Sparkle calls
/// these on the main thread; each call moves the card to a phase and wires its buttons to Sparkle's replies.
///
/// Downloads that Sparkle runs on its own in the background never come through here: those reach
/// `Updater` through the delegate once they are ready to install.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    let window: UpdateWindow
    private var release: UpdateRelease?
    private var received: UInt64 = 0
    private var expected: UInt64 = 0
    /// The user started this cycle (a check, or "Update" on the card), so the card may take the keyboard.
    private var userInitiated = false

    init(window: UpdateWindow) {
        self.window = window
    }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // Info.plist turns automatic checks on (SUEnableAutomaticChecks), so Sparkle shouldn't ask; if it does,
        // answer the way the Settings default reads.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        userInitiated = true
        window.show(.checking, focus: true, secondary: { [weak self] in
            cancellation()
            self?.window.close()
        })
    }

    func showUpdateFound(with appcastItem: SUAppcastItem, state: SPUUserUpdateState, reply: @escaping (SPUUserUpdateChoice) -> Void) {
        let release = UpdateRelease(item: appcastItem)
        self.release = release
        userInitiated = state.userInitiated
        let focus = userInitiated
        let later = { [weak self] in
            reply(.dismiss)
            self?.window.close()
        }
        let install = { [weak self] in
            self?.userInitiated = true
            reply(.install)
        }
        if appcastItem.isInformationOnlyUpdate {
            window.show(.available(release), focus: focus, primary: { [weak self] in
                if let url = appcastItem.infoURL { NSWorkspace.shared.open(url) }
                reply(.dismiss)
                self?.window.close()
            }, secondary: later)
            return
        }
        switch state.stage {
        case .notDownloaded where state.userInitiated:
            // The user asked: start downloading straight away; the card shows the progress.
            reply(.install)
        case .notDownloaded:
            window.show(.available(release), focus: focus, primary: install, secondary: later)
        case .downloaded, .installing:
            window.show(.ready(release), focus: focus, primary: { [weak self] in
                self?.window.show(.installing(release, waitingToQuit: false), focus: true)
                install()
            }, secondary: later)
        @unknown default:
            window.show(.available(release), focus: focus, primary: install, secondary: later)
        }
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        // Only for appcasts that link their notes instead of embedding them; Tern's embed them.
        guard var release, release.notes.isEmpty,
              let text = String(data: downloadData.data, encoding: .utf8) else { return }
        release.notes = ReleaseNotes(text)
        self.release = release
        if case .available = window.model.phase { window.model.phase = .available(release) }
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let done = { [weak self] in
            acknowledgement()
            self?.window.close()
        }
        let reason = (error as NSError).userInfo[SPUNoUpdateFoundReasonKey] as? Int
        switch reason.flatMap({ SPUNoUpdateFoundReason(rawValue: OSStatus($0)) }) {
        case .systemIsTooOld:
            window.show(.failed("The newest Tern needs a newer version of macOS."), focus: userInitiated, secondary: done)
        default:
            window.show(.upToDate, focus: userInitiated, primary: done)
        }
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        window.show(.failed(Self.message(for: error)), focus: userInitiated, secondary: { [weak self] in
            acknowledgement()
            self?.window.close()
        })
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        received = 0
        expected = 0
        window.show(.downloading(release, received: 0, expected: 0), focus: userInitiated, secondary: { [weak self] in
            cancellation()
            self?.window.close()
        })
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expected = expectedContentLength
        window.model.phase = .downloading(release, received: received, expected: expected)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        received += length
        // A server that sent no length, or less than it sends: grow the total so the line never overflows.
        if received > expected, expected > 0 { expected = received }
        window.model.phase = .downloading(release, received: received, expected: expected)
    }

    func showDownloadDidStartExtractingUpdate() {
        window.show(.preparing(release, progress: nil), focus: userInitiated)
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        window.model.phase = .preparing(release, progress: progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        guard let release else { return reply(.install) }
        window.show(.ready(release), focus: userInitiated, primary: { [weak self] in
            self?.window.show(.installing(release, waitingToQuit: false), focus: true)
            reply(.install)
        }, secondary: { [weak self] in
            // The update still installs when Tern quits.
            reply(.dismiss)
            self?.window.close()
        })
    }

    func showInstallingUpdate(withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void) {
        window.show(.installing(release, waitingToQuit: !applicationTerminated), focus: userInitiated, primary: retryTerminatingApplication)
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
        window.close()
    }

    func showUpdateInFocus() {
        window.focus()
    }

    func dismissUpdateInstallation() {
        release = nil
        userInitiated = false
        window.close()
    }

    /// One plain line for the error card.
    static func message(for error: Error) -> String {
        let error = error as NSError
        let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError
        if error.domain == NSURLErrorDomain || underlying?.domain == NSURLErrorDomain {
            return "Couldn't reach the update server."
        }
        if error.domain == SUSparkleErrorDomain, error.code == Int(SUError.runningFromDiskImageError.rawValue) {
            return "Move Tern to Applications to update it."
        }
        return error.localizedDescription
    }
}

extension UpdateRelease {
    init(item: SUAppcastItem) {
        self.init(version: item.displayVersionString, notes: ReleaseNotes(item.itemDescription))
    }
}
