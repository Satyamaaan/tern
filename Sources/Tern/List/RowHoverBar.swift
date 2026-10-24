import AppKit
import SwiftUI
import TernCore

/// The buttons that replace a row's tags and time on hover: Archive (Move to Inbox in the Archive list),
/// Snooze, `…`; on a draft row, Discard and `…`.
struct RowHoverBar: View {
    let model: AppModel
    let keys: [ThreadKey]
    var onMenuTrackingChange: (Bool) -> Void = { _ in }
    @State private var snoozeAnchor = MenuAnchor.AnchorView()
    @State private var moreAnchor = MenuAnchor.AnchorView()
    @State private var snoozeOpen = false
    @State private var moreOpen = false

    var body: some View {
        HStack(spacing: 2) {
            if !keys.isEmpty, keys.allSatisfy(model.isDraftRow) {
                HoverButton(icon: .trash, help: hint("Discard draft", "trash")) { model.discardDrafts(keys) }
            } else {
                if model.inLedger {
                    HoverButton(icon: .done, help: hint("Mark done", "commitmentDone")) { model.markCommitmentsDone(on: keys) }
                } else if model.inArchive {
                    HoverButton(icon: .inbox, help: hint("Move to Inbox", "moveToInbox")) { model.perform(.moveToInbox, on: keys) }
                } else {
                    HoverButton(icon: .archive, help: hint("Archive", "archive")) { model.perform(.archive, on: keys) }
                }
                if !model.inLedger {
                    HoverButton(icon: .snoozed, help: hint("Snooze", "snooze"), active: snoozeOpen) {
                        snoozeAnchor.popUp(ThreadMenu.snoozeMenu(model: model, keys: keys)) { tracking in
                            snoozeOpen = tracking
                            onMenuTrackingChange(tracking)
                        }
                    }
                    .background(MenuAnchor(view: snoozeAnchor).accessibilityHidden(true))
                }
            }
            HoverButton(icon: .ellipsis, help: "More actions", active: moreOpen) {
                guard let registry = model.registry else { return }
                // The menu's commands act on the selection, so make the hovered row the selection first.
                if keys.count == 1, let key = keys.first, !model.isSelected(key) { model.select(key) }
                let menu = ThreadMenu.make(registry: registry, model: model)
                moreAnchor.popUp(menu) { tracking in
                    moreOpen = tracking
                    onMenuTrackingChange(tracking)
                }
            }
            .background(MenuAnchor(view: moreAnchor).accessibilityHidden(true))
        }
        .environment(model.services)
        .frame(width: ThreadRowView.hoverWidth, height: 24, alignment: .trailing)
    }

    private func hint(_ title: String, _ id: String) -> String { model.registry?.hint(title, id) ?? title }
}

/// A row's icon button. The row under it already has the `hover` fill, so the button's hover is `selected`
/// and its press a step stronger.
private struct HoverButton: View {
    let icon: Icon
    let help: String
    var active = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            IconView(icon: icon, size: 15)
                .foregroundStyle(Color(Theme.text2))
                .frame(width: 26, height: 24)
        }
        .buttonStyle(PressFillStyle(rest: active ? Theme.selected : nil, hover: Theme.selected, pressed: Theme.selectedFocus))
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Every thread action with its shortcut, for the row `…` button and right-click.
@MainActor
enum ThreadMenu {
    static func make(registry: CommandRegistry, model: AppModel) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let target = MenuTarget.shared
        target.registry = registry
        var section: Int?
        for command in registry.commands where command.menu == .message {
            if let section, section != command.section { menu.addItem(.separator()) }
            section = command.section
            if command.id == "snooze" {
                menu.addItem(snoozeItem(model: model))
                continue
            }
            let key = command.menuKey
            let item = NSMenuItem(title: command.displayTitle, action: #selector(MenuTarget.run(_:)), keyEquivalent: key?.keyEquivalent ?? "")
            item.target = target
            item.representedObject = command.id
            item.keyEquivalentModifierMask = key?.menuModifiers ?? []
            item.isEnabled = registry.canRun(command)
            menu.addItem(item)
            if command.id == "project", model.prefs.splitInbox { menu.addItem(moveToTabItem(registry: registry, model: model)) }
            // A conversation with a draft of yours in it: its draft can go without the conversation.
            if command.id == "trash", let discard = registry["discardDraft"], discard.isVisible(), registry.canRun(discard) {
                let item = NSMenuItem(title: discard.displayTitle, action: #selector(MenuTarget.run(_:)), keyEquivalent: "")
                item.target = target
                item.representedObject = discard.id
                menu.addItem(item)
            }
        }
        return menu
    }

    /// "Move to Tab" ▸ Gmail's tabs, the selection's own ticked. Each runs its `moveToTab.*` command, so
    /// the keys the user gave one show here.
    static func moveToTabItem(registry: CommandRegistry, model: AppModel) -> NSMenuItem {
        let target = MenuTarget.shared
        let current = Set(model.targets.compactMap { model.row($0)?.inboxTab })
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for tab in InboxTab.allCases {
            guard let command = registry["moveToTab.\(tab.rawValue)"] else { continue }
            let key = command.menuKey
            let item = NSMenuItem(title: tab.title, action: #selector(MenuTarget.run(_:)), keyEquivalent: key?.keyEquivalent ?? "")
            item.keyEquivalentModifierMask = key?.menuModifiers ?? []
            item.target = target
            item.representedObject = command.id
            item.image = Icon.tab(tab).tinted(Theme.tabColor(tab), size: 14)
            item.state = current == [tab] ? .on : .off
            item.isEnabled = registry.canRun(command)
            submenu.addItem(item)
        }
        let item = NSMenuItem(title: "Move to Tab", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    private static func snoozeItem(model: AppModel) -> NSMenuItem {
        let key = MenuTarget.shared.registry?["snooze"]?.menuKey
        let item = NSMenuItem(title: "Snooze", action: nil, keyEquivalent: key?.keyEquivalent ?? "")
        item.keyEquivalentModifierMask = key?.menuModifiers ?? []
        item.submenu = snoozeMenu(model: model, keys: model.targets)
        return item
    }

    static func snoozeMenu(model: AppModel, keys: [ThreadKey]) -> NSMenu {
        let target = MenuTarget.shared
        let submenu = NSMenu()
        for option in SnoozeOption.presets() {
            let item = NSMenuItem(title: "\(option.title)  —  \(option.detail)", action: #selector(MenuTarget.runClosure(_:)), keyEquivalent: "")
            item.target = target
            item.representedObject = MenuTarget.Closure { model.perform(.snooze(until: option.date), on: keys) }
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let pick = NSMenuItem(title: "Pick date…", action: #selector(MenuTarget.runClosure(_:)), keyEquivalent: "")
        pick.target = target
        pick.representedObject = MenuTarget.Closure { model.snoozeDateFor = keys }
        submenu.addItem(pick)
        return submenu
    }
}

/// Target for menus built outside the main menu.
@MainActor
final class MenuTarget: NSObject {
    static let shared = MenuTarget()
    weak var registry: CommandRegistry?

    final class Closure: NSObject {
        let run: @MainActor () -> Void
        init(_ run: @escaping @MainActor () -> Void) { self.run = run }
    }

    @objc func run(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        registry?.run(id)
    }

    @objc func runClosure(_ sender: NSMenuItem) {
        (sender.representedObject as? Closure)?.run()
    }
}
