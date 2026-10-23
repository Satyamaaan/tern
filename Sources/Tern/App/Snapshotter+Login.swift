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
        // Offscreen renders can't draw Liquid Glass; the card shows its solid surface over a wallpaper-like backdrop.
        LoginCard.drawsGlass = false
        defer { LoginCard.drawsGlass = true }
        let height = NSHostingView(rootView: LoginPopupView(sender: "Linear · linear.app", account: "alex@kiteworks.dev", credentials: credentials,
            perform: { _ in }, dismiss: {}).frame(width: LoginCard.width)).fittingSize.height
        let backdrop = LinearGradient(colors: [Color(red: 0.36, green: 0.52, blue: 0.78), Color(red: 0.86, green: 0.62, blue: 0.5)],
                                      startPoint: .top, endPoint: .bottom)
        for (name, open, copied) in [("hidden", false, false), ("open", true, false), ("copied", true, true)] {
            let state = LoginCardState(size: CGSize(width: LoginCard.width, height: height))
            state.isOpen = open
            state.copied = copied
            let card = LoginCardView(state: state, sender: "Linear · linear.app", account: "alex@kiteworks.dev", credentials: credentials,
                                     perform: { _ in }, dismiss: {}, hovering: { _ in })
                .transaction { $0.animation = nil }
            standalone(card.background(backdrop), size: NSSize(width: 480, height: height + 64),
                       to: directory.appendingPathComponent("login-card-\(name).png"), dark: false)
        }

        model.openSettings(.notifications)
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        both("login-settings")
    }
}
