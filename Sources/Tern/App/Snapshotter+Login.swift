import AppKit
import SwiftUI
import TernCore

extension Snapshotter {
    /// `TERN_LOGIN_SNAPSHOT_ONLY=1`: the newest inbox thread in the reader (its sign-in strip when the mail is fresh),
    /// the login card on its own (hidden, open, copied), and the Notifications settings with its login popup row, light and dark.
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
        // Offscreen renders cannot sample the desktop; verify the solid accessibility surface here.
        LoginCard.drawsGlass = false
        defer { LoginCard.drawsGlass = true }
        let backdrop = LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.86, green: 0.62, blue: 0.5)],
                                      startPoint: .top, endPoint: .bottom)
        for name in ["open", "copied", "hidden", "code-only", "link-only", "no-notch", "long-account"] {
            let items = name == "code-only" ? [credentials[0]] : name == "link-only" ? [credentials[1]] : credentials
            let account = name == "long-account" ? "an-exceptionally-long-account@northwind-studio.example.com" : "alex@kiteworks.dev"
            let closed = CGSize(width: 184, height: name == "no-notch" ? 0 : 32)
            let height = NSHostingView(rootView: LoginPopupView(sender: "Linear · linear.app", account: account, credentials: items,
                perform: { _ in }, dismiss: {}).frame(width: LoginCard.width)).fittingSize.height + closed.height
            let state = LoginCardState(size: CGSize(width: LoginCard.width, height: height), closed: closed)
            state.isOpen = name != "hidden"
            state.copied = name == "copied"
            let card = LoginCardView(state: state, sender: "Linear · linear.app", account: account, credentials: items,
                                     perform: { _ in }, dismiss: {}, hovering: { _ in })
                .transaction { $0.animation = nil }
            standalone(card.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(backdrop),
                       size: NSSize(width: 500, height: height + 40),
                       to: directory.appendingPathComponent("login-card-\(name).png"), dark: false)
        }

        model.openSettings(.notifications)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        both("login-settings")
    }
}
