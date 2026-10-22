import AppKit
import SwiftUI
import TernCore

/// Opens the database, builds the services and model, and owns the windows.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ShellActions {
    private(set) var options = LaunchOptions.current()
    private(set) var services: AppServices!
    private(set) var model: AppModel!
    private var registry: CommandRegistry!
    private var router: KeyRouter!
    private var mainMenu: MainMenu!
    private var palette: PaletteController!
    private var window: MainWindow?
    private var onboardingWindow: NSWindow?
    private var snoozeTimer: Timer?
    private var integration: Integration?
    /// Auto-update; nil in development builds.
    private(set) var updater: Updater?
    private var movePrompt: MovePrompt?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Timing.appStarted = Timing.sinceProcessStart()
        let launch = Timing.begin("launch")
        Theme.registerFonts()
        NSApp.appearance = Preferences.shared.appearance.appearance
        // Start the reader's web content process now, so it loads while the list fills.
        ReaderWebEngine.prewarm()

        DemoReset.applyIfRequested(options)
        let database: AppDatabase
        do {
            database = try AppDatabase.open(at: options.databaseURL)
        } catch {
            fail("Tern couldn't open its database at \(options.databaseURL.path).", error)
            return
        }
        let services = AppServices(store: MailStore(database))
        self.services = services
        model = AppModel(services: services, isFake: options.isFake, databaseURL: options.databaseURL)
        registry = CommandRegistry(model: model, shell: self)
        model.registry = registry
        wire(services)
        if options.snapshotDirectory == nil, !CommandLine.arguments.contains("--check"), !options.isTypingCheck {
            let integration = Integration(services: services, model: model)
            integration.wire()
            self.integration = integration
            if !options.isFake { SenderLogos.shared.start() }
        }

        mainMenu = MainMenu(registry: registry)
        NSApp.mainMenu = mainMenu.build()
        ReaderWebEngine.shared.keyActions = KeyRouter.pageKeyMap(registry)
        // An edited shortcut shows (and fires) in the menu bar and the reader page at once.
        NotificationCenter.default.addObserver(forName: CommandRegistry.shortcutsDidChange, object: registry, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let mainMenu = self.mainMenu else { return }
                NSApp.mainMenu = mainMenu.build()
                ReaderWebEngine.shared.keyActions = KeyRouter.pageKeyMap(self.registry)
            }
        }
        model.startObservations()

        if CommandLine.arguments.contains("--check") {
            SelfCheck(model: model, registry: registry).run()
        }
        #if DEBUG
        if options.isTypingCheck {
            TypingCheck(model: model, registry: registry).start()
            return
        }
        #endif
        if let directory = options.snapshotDirectory {
            Snapshotter(model: model, registry: registry).run(into: directory)
            return
        }

        palette = PaletteController(model: model, registry: registry)
        router = KeyRouter(registry: registry)
        router.paletteKeys = { [weak self] key in self?.palette.handle(key) ?? false }
        let window = makeMainWindow()
        router.mainWindow = window
        router.install()
        window.makeKeyAndOrderFront(nil)
        // A window shown for the first time gives its first text field (the search pill) the keyboard;
        // the list should have it, or j and k would type.
        model.focusList()
        window.displayIfNeeded()
        NSApp.activate()

        let total = Timing.end(launch)
        #if DEBUG
        print(String(format: "Tern launch: %.0f ms since process start, %.0f ms in didFinishLaunching, %d rows",
                     Timing.sinceProcessStart(), total, model.snapshot.order.count))
        #endif

        if model.accounts.isEmpty {
            if options.isFake { seedDemoMail(database) } else { showOnboarding() }
        }
        startSnoozeTimer()
        startUpdates()
        // The key bindings files can reserve more Control keys; read them now the window is up, not before.
        registry.loadKeyBindings()
    }

    /// Release builds: the updater, and the offer to move to Applications when Tern runs from elsewhere.
    private func startUpdates() {
        guard ReleaseBuild.isCurrent, !options.isHeadless else { return }
        let location = AppLocation.current()
        updater = Updater.start(options: options, location: location)
        movePrompt = MovePrompt.offerIfNeeded(options: options, location: location)
    }

    /// Brings snoozed threads back to the inbox when their time comes. Checked every minute and on wake.
    private func startSnoozeTimer() {
        let store = services.store
        let writes = model.writes
        let wake = {
            writes.async {
                _ = try? store.wakeSnoozed()
                try? store.database.writer.write { try Ledger.sweep($0) }
            }
        }
        Task.detached(priority: .utility) { try? Ledger.rebuildWaiting(in: store.database, onlyIfNeeded: true) }
        wake()
        snoozeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in wake() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in wake() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Saves a settings edit not yet committed and finishes queued writes (at most 1 s), then lets sync put in-flight
    /// work back in its queue before the app goes (at most 2 s).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model?.prepareToQuit()
        guard let integration, integration.sync != nil else { return .terminateNow }
        Task {
            await integration.shutdown()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        integration?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: Services

    private func wire(_ services: AppServices) {
        services.perform = { [weak model] action, keys in model?.perform(action, on: keys) }
        services.discardDraft = { [weak model] message, thread in model?.discardDraft(message, in: thread) }
        services.compose = { [weak services] request in
            guard let services else { return }
            Composer.open(request, services: services)
        }
        services.openDraftMessage = { [weak services] key in
            guard let services else { return }
            Composer.openDraftMessage(key, services: services)
        }
        services.showThread = { [weak self] key in
            guard let self else { return }
            self.showMainWindow()
            self.model.reveal(key)
        }
        services.archiveSent = { [weak model] key in await model?.archiveSent(key) }
        ReaderWebEngine.shared.webView.didTakeFocus = { [weak model] in model?.focus = .reader }
    }

    // MARK: Windows

    private func makeMainWindow() -> MainWindow {
        let root = MainView(palette: palette)
            .environment(model)
            .environment(services)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = []
        let window = MainWindow(contentView: hosting)
        self.window = window
        // The window stays in memory when closed, so the settings page's fields never go away: save what they hold.
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.settings?.commitEdits() }
        }
        return window
    }

    func showMainWindow() {
        let created = window == nil
        if created { router.mainWindow = makeMainWindow() }
        window?.makeKeyAndOrderFront(nil)
        if created { model.focusList() }
        NSApp.activate()
    }

    /// ⌘,, the gear, the menus and ⌘K: the settings page in the main window (opened again if it was
    /// closed). ⌘, while the page is in front takes it away again.
    func showSettings(_ section: SettingsSection?) {
        let inFront = window?.isKeyWindow == true && model.settingsOpen
        showMainWindow()
        if inFront && section == nil { model.closeSettings() } else { model.openSettings(section, updater: updater) }
    }

    func checkForUpdates() {
        updater?.checkForUpdates()
    }

    func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Tern",
            .credits: NSAttributedString(
                string: "Mail at the speed you think.",
                attributes: [.font: Theme.ui(11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    func addAccount() {
        // With several Google clients the user picks one there.
        if services.googleClients().count > 1 { return model.openSettings(.accounts) }
        Task {
            do {
                _ = try await services.connectAccount()
            } catch {
                if error is CancellationError { return }
                let alert = NSAlert()
                alert.messageText = "Couldn't add the account"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 560),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = Theme.bg
            window.contentView = NSHostingView(rootView: OnboardingView(
                onFinish: { [weak self] in self?.finishOnboarding() },
                onDemo: { [weak self] in self?.relaunchWithDemoMail() }
            ).environment(model).environment(services))
            window.center()
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    private func finishOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        showMainWindow()
    }

    /// "Try it with demo mail": start a second copy on the fake mailbox and quit this one.
    func relaunchWithDemoMail() {
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.arguments = ["--fake"]
            configuration.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: bundle, configuration: configuration) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        } else if let executable = Bundle.main.executableURL {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["--fake"]
            try? process.run()
            NSApp.terminate(nil)
        }
    }

    /// First launch in demo mode: write the fake mailbox in the background; the observations fill the
    /// window when the transaction lands.
    private func seedDemoMail(_ database: AppDatabase) {
        model.isSeeding = true
        DispatchQueue.global(qos: .userInitiated).async {
            do { try FakeMailbox.populate(database) } catch { NSLog("Tern: seeding demo mail failed: \(error)") }
            DispatchQueue.main.async { MainActor.assumeIsolated { self.model.isSeeding = false } }
        }
    }

    private func fail(_ message: String, _ error: Error) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.runModal()
        NSApp.terminate(nil)
    }
}

extension AppModel {
    /// Shows a thread from outside the list (notification, mailto): selects it if listed, else opens it.
    func reveal(_ key: ThreadKey) {
        if snapshot.rows[key] == nil { pendingCursor = key }
        checked = []
        setCursor(key, open: true)
        focus = .reader
    }
}
