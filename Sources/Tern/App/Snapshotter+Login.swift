import AppKit
import SwiftUI
import TernCore

extension Snapshotter {
    /// `TERN_LOGIN_SNAPSHOT_ONLY=1`: the newest inbox thread in the reader (its sign-in strip when the mail is fresh),
    /// the login popup card on its own, and the Notifications settings with its login popup row, light and dark.
    func loginShots(_ window: MainWindow, _ directory: URL) {
        func both(_ name: String) {
            render(window, appearance: .aqua, to: directory.appendingPathComponent("\(name)-light.png"))
            render(window, appearance: .darkAqua, to: directory.appendingPathComponent("\(name)-dark.png"))
        }
        showForWebKit(window)
        let rows = (try? model.store.threadRows(in: Mailbox(.inbox), limit: 1)) ?? []
        if let thread = rows.first?.id {
            var painted = false
            ReaderModel.renderObserver = { rendered, _ in if rendered == thread { painted = true } }
            model.reveal(thread)
            if model.listOnly { model.readerExpanded = true }
            let end = Date().addingTimeInterval(3)
            while !painted, Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
            ReaderModel.renderObserver = nil
            both("login-reader")
        }

        let credentials: [LoginCredential] = [.code("482913"),
                                              .magicLink(URL(string: "https://linear.app/auth/magic/Zk3P9qLmA7xR2vT8wBn5")!)]
        let height = NSHostingView(rootView: LoginPopupView(sender: "Linear · linear.app", account: "alex@kiteworks.dev", credentials: credentials,
            topInset: 32, perform: { _ in }, dismiss: {}).frame(width: LoginIslandGeometry.openWidth)).fittingSize.height
        // The island as it hangs from a 32 pt notch, over a strip of menu bar and desktop, half-way down and open.
        for (name, open) in [("closed", false), ("open", true)] {
            let state = LoginIslandState(closed: CGSize(width: 190, height: 32), open: CGSize(width: LoginIslandGeometry.openWidth, height: height))
            state.isOpen = open
            let island = LoginIsland(state: state, sender: "Linear · linear.app", account: "alex@kiteworks.dev", credentials: credentials,
                                     perform: { _ in }, dismiss: {}, hovering: { _ in })
                .transaction { $0.animation = nil }
            standalone(island.background(alignment: .top) {
                    Color(white: 0.85).frame(height: 32)
                }, size: NSSize(width: 520, height: 260),
                       to: directory.appendingPathComponent("login-island-\(name).png"), dark: false)
        }
        let copied = LoginIslandState(closed: CGSize(width: 190, height: 32), open: CGSize(width: LoginIslandGeometry.openWidth, height: height))
        copied.isOpen = true
        copied.copied = true
        standalone(LoginIsland(state: copied, sender: "Linear · linear.app", account: "alex@kiteworks.dev", credentials: credentials,
                               perform: { _ in }, dismiss: {}, hovering: { _ in }).transaction { $0.animation = nil },
                   size: NSSize(width: 520, height: 260), to: directory.appendingPathComponent("login-island-copied.png"), dark: false)

        model.openSettings(.notifications)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        both("login-settings")
    }
}
