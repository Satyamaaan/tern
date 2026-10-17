import AppKit
import SwiftUI
import TernCore

/// The one account control in the main window: a field showing the scope; click for the menu.
struct AccountSwitcher: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private let shape = RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)

    var body: some View {
        Button(action: showMenu) {
            HStack(spacing: 10) {
                dots
                Text(title)
                    .font(.ui(13, .medium))
                    .foregroundStyle(Color(Theme.text1))
                    .lineLimit(1)
                Spacer(minLength: 4)
                IconView(icon: .chevronDown, size: 12)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(shape.fill(Color(scheme == .dark ? Theme.raised : Theme.bg)))
            .overlay(shape.strokeBorder(Color(hovering ? Theme.hairlineStrong : Theme.hairline), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Switch account (⌘0–⌘9)")
    }

    private var title: String {
        model.scopedAccount.map(model.accountTitle) ?? "All accounts"
    }

    @ViewBuilder private var dots: some View {
        let shown = model.scopedAccount.map { [$0] } ?? Array(model.accounts.prefix(3))
        HStack(spacing: -4) {
            ForEach(shown) { account in
                Circle()
                    .fill(Color(Theme.accountColor(account.colorIndex)))
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color(scheme == .dark ? Theme.raised : Theme.bg), lineWidth: 2).padding(-2))
            }
        }
        .padding(.leading, 2)
        .padding(.trailing, shown.count > 1 ? 4 : 0)
    }

    private func showMenu() {
        guard let event = NSApp.currentEvent, let view = event.window?.contentView, let registry = model.registry else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = MenuTarget.shared
        target.registry = registry
        func add(_ id: String, title: String, image: NSImage? = nil, on: Bool = false) {
            guard let command = registry[id] else { return }
            let key = command.menuKey
            let item = NSMenuItem(title: title, action: #selector(MenuTarget.run(_:)), keyEquivalent: key?.keyEquivalent ?? "")
            item.keyEquivalentModifierMask = key?.modifiers ?? []
            item.target = target
            item.representedObject = id
            item.image = image
            item.state = on ? .on : .off
            menu.addItem(item)
        }
        add("scope.all", title: "All accounts", on: model.scope == .all)
        for (index, account) in model.accounts.prefix(9).enumerated() {
            add("scope.\(index + 1)", title: model.accountTitle(account), image: Theme.swatch(Theme.accountColor(account.colorIndex)),
                on: model.scope == .account(account.id))
        }
        menu.addItem(.separator())
        add("addAccount", title: "Add account…")
        add("settings", title: "Settings…")
        let origin = view.convert(event.locationInWindow, from: nil)
        menu.popUp(positioning: menu.items.first, at: NSPoint(x: origin.x - 60, y: origin.y), in: view)
    }
}
