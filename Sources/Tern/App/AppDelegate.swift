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
    private var settingsWindow: NSWindow?
    private var settingsState: SettingsState?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let launch = Timing.begin("launch")
        Theme.registerFonts()
        NSApp.appearance = Preferences.shared.appearance.appearance

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

        mainMenu = MainMenu(registry: registry)
        NSApp.mainMenu = mainMenu.build()
        model.startObservations()

        if CommandLine.arguments.contains("--check") {
            SelfCheck(model: model, registry: registry).run()
        }
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
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { showMainWindow() }
        return true
    }

    // MARK: Services

    private func wire(_ services: AppServices) {
        services.perform = { [weak model] action, keys in model?.perform(action, on: keys) }
        services.compose = { [weak services] request in
            guard let services else { return }
            Composer.open(request, services: services)
        }
        services.showThread = { [weak self] key in
            guard let self else { return }
            self.showMainWindow()
            self.model.reveal(key)
        }
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
        return window
    }

    func showMainWindow() {
        if window == nil { router.mainWindow = makeMainWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func showSettings(_ section: SettingsSection?) {
        if settingsWindow == nil {
            let state = SettingsState(model: model, shell: self)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 760, height: 540),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Settings"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.backgroundColor = Theme.bg
            window.contentView = NSHostingView(rootView: SettingsView(state: state).environment(model).environment(services))
            window.center()
            window.setFrameAutosaveName("TernSettings")
            settingsWindow = window
            settingsState = state
        }
        if let section { settingsState?.section = section }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate()
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
        Task {
            do {
                _ = try await services.connectAccount()
            } catch {
                let alert = NSAlert()
                alert.messageText = "Adding accounts isn't available yet"
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
        if snapshot.rows[key] != nil {
            setCursor(key, open: true)
        } else {
            pendingCursor = key
            setCursor(key, open: true)
        }
        focus = .reader
    }
}
