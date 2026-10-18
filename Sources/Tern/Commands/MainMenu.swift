import AppKit

/// The menu bar, built from the command registry so it always matches the palette and the keyboard. The app
/// builds it again whenever a shortcut changes.
@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    private let registry: CommandRegistry

    init(registry: CommandRegistry) {
        self.registry = registry
    }

    func build() -> NSMenu {
        let main = BareKeySafeMenu(title: "Main Menu")
        for name in MenuName.allCases {
            let menu = NSMenu(title: name.rawValue)
            switch name {
            case .app: buildAppMenu(menu)
            case .file:
                addCommands(.file, to: menu)
                menu.addItem(.separator())
                menu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
            case .edit: buildEditMenu(menu)
            case .view:
                addCommands(.view, to: menu)
                menu.addItem(.separator())
                let fullScreen = menu.addItem(withTitle: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
                fullScreen.keyEquivalentModifierMask = [.command, .control]
            case .window:
                menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
                menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
                menu.addItem(.separator())
                addCommands(.window, to: menu)
                menu.addItem(.separator())
                menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
                NSApp.windowsMenu = menu
            case .help:
                addCommands(.help, to: menu)
                NSApp.helpMenu = menu
            default:
                addCommands(name, to: menu)
            }
            let item = NSMenuItem(title: name.rawValue, action: nil, keyEquivalent: "")
            item.submenu = menu
            main.addItem(item)
        }
        return main
    }

    private func buildAppMenu(_ menu: NSMenu) {
        addCommands(.app, to: menu)
        menu.addItem(.separator())
        let services = NSMenu(title: "Services")
        menu.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(withTitle: "Hide Tern", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Tern", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func buildEditMenu(_ menu: NSMenu) {
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(withTitle: "Paste and Match Style", action: #selector(NSTextView.pasteAsPlainText(_:)), keyEquivalent: "V")
            .keyEquivalentModifierMask = [.command, .option]
        menu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        menu.addItem(.separator())
        addCommands(.edit, to: menu)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Emoji & Symbols", action: #selector(NSApplication.orderFrontCharacterPalette(_:)), keyEquivalent: " ")
            .keyEquivalentModifierMask = [.command, .control]
    }

    private func addCommands(_ name: MenuName, to menu: NSMenu) {
        var section: Int?
        for command in registry.commands where command.menu == name && !command.paletteOnly {
            if let section, section != command.section { menu.addItem(.separator()) }
            section = command.section
            let key = command.menuKey
            let item = NSMenuItem(title: command.title, action: #selector(runCommand(_:)), keyEquivalent: key?.keyEquivalent ?? "")
            item.target = self
            item.representedObject = command.id
            if let key { item.keyEquivalentModifierMask = key.menuModifiers }
            if let chord = command.chord { item.toolTip = "Shortcut: \(chord)" }
            menu.addItem(item)
        }
    }

    @objc private func runCommand(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        if registry[id]?.paletteOnly == false { registry.model.prefs.noteRecent(id) }
        registry.run(id)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let id = item.representedObject as? String, let command = registry[id] else { return true }
        item.title = command.displayTitle
        item.isHidden = !command.isVisible()
        return registry.canRun(command)
    }
}

/// Main menu that leaves bare keys alone. Menu items show shortcuts like `e` or `⇧R`, but those keys
/// must never fire while someone types in a text field, so only ⌘ and ⌃ combinations match here;
/// `KeyRouter` handles bare keys itself.
final class BareKeySafeMenu: NSMenu {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard !event.modifierFlags.isDisjoint(with: [.command, .control]) else { return false }
        return super.performKeyEquivalent(with: event)
    }
}
