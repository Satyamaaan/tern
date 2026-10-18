import AppKit

/// Moves the running copy of Tern into Applications and reopens it from there.
enum AppMover {
    enum Failure: LocalizedError {
        case stillRunning

        var errorDescription: String? {
            switch self {
            case .stillRunning: "The copy of Tern in Applications didn't quit. Quit it and try again."
            }
        }
    }

    /// /Applications when it can be written, else ~/Applications.
    static func destinationFolder() throws -> URL {
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        if FileManager.default.isWritableFile(atPath: system.path) { return system }
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return user
    }

    /// Copies Tern into Applications (an older copy there quits and goes to the Trash), then quits. Once this
    /// process has gone, a small helper opens the new copy and ejects the disk image Tern came from. The copy runs
    /// off the main thread.
    @MainActor
    static func move(_ location: AppLocation) async throws {
        let folder = try destinationFolder()
        let destination = folder.appendingPathComponent(location.bundleURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) { try await quitCopy(at: destination) }
        let bundle = location.bundleURL
        _ = try await Task.detached { try install(bundle, into: folder) }.value
        reopen(destination, ejecting: location.volumeURL)
    }

    /// Copies the bundle into `folder` without quarantine, replacing (trashing) a copy already there, and returns
    /// where it went.
    static func install(_ bundle: URL, into folder: URL) throws -> URL {
        let files = FileManager.default
        let destination = folder.appendingPathComponent(bundle.lastPathComponent)
        // Copy next to the destination first (same volume), so a copy that fails changes nothing.
        let staging = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destination, create: true)
        let staged = staging.appendingPathComponent(destination.lastPathComponent)
        defer { try? files.removeItem(at: staging) }
        try files.copyItem(at: bundle, to: staged)
        // Already approved by Gatekeeper; a quarantined copy would ask again on its first launch.
        run("/usr/bin/xattr", "-d", "-r", "com.apple.quarantine", staged.path)
        if files.fileExists(atPath: destination.path) {
            try files.trashItem(at: destination, resultingItemURL: nil)
        }
        try files.moveItem(at: staged, to: destination)
        return destination
    }

    /// Asks a copy of Tern running from `url` to quit, and waits up to five seconds for it.
    @MainActor
    private static func quitCopy(at url: URL) async throws {
        let me = NSRunningApplication.current
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0 != me && $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }
        guard !running.isEmpty else { return }
        running.forEach { $0.terminate() }
        for _ in 0..<50 where running.contains(where: { !$0.isTerminated }) {
            try await Task.sleep(for: .milliseconds(100))
        }
        if running.contains(where: { !$0.isTerminated }) { throw Failure.stillRunning }
    }

    @MainActor
    private static func reopen(_ app: URL, ejecting volume: URL?) {
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /usr/bin/open "$2"
        if [ -n "$3" ]; then /usr/bin/hdiutil detach "$3" -quiet; fi
        """
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", script, "tern-move", String(getpid()), app.path, volume?.path ?? ""]
        do {
            try helper.run()
        } catch {
            NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        }
        NSApp.terminate(nil)
    }

    private static func run(_ tool: String, _ arguments: String...) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}
