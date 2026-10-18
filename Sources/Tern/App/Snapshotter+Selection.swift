import AppKit
import TernCore

// The list's selection in each state it can be in, for visual review: with and without the keyboard, under a
// date header, beside a hovered row, several rows, two-line rows in the reading pane, scrolled under the sticky
// header, and in search results above the Gmail footer.
extension Snapshotter {
    func selectionShots(_ window: MainWindow, _ directory: URL) {
        func shot(_ name: String) {
            render(window, appearance: .aqua, to: directory.appendingPathComponent("selection-\(name)-light.png"))
            render(window, appearance: .darkAqua, to: directory.appendingPathComponent("selection-\(name)-dark.png"))
        }
        guard let list = model.listView as? MessageListController else { return }
        // Preferences persist between runs: set the pane explicitly, and put it back after.
        let readingPane = model.prefs.readingPane
        model.prefs.readingPane = false
        model.showSplit(nil)
        model.show(.inbox)
        settle(window)
        let order = model.snapshot.order
        guard order.count > 40 else { return }
        func tableRow(_ key: ThreadKey) -> Int? { model.snapshot.itemIndex[key] }

        model.select(order[2])
        model.focusList()
        shot("focused")
        model.focus = .reader
        shot("unfocused")
        model.focusList()

        model.select(order[0])
        shot("first")

        model.select(order[3])
        list.setHovered(tableRow(order[2]))
        shot("hovered-above")
        list.setHovered(tableRow(order[4]))
        shot("hovered-below")
        list.setHovered(nil)

        model.select(order[2])
        model.moveCursor(1, extend: true)
        model.moveCursor(1, extend: true)
        shot("multiple")
        model.select(order[2])

        // Down the list, then back up with k until the row scrolls in right under the sticky header.
        model.select(order[min(order.count - 1, 70)])
        for _ in 0..<30 { model.moveCursor(-1) }
        settle(window)
        shot("scrolled")
        model.moveToTop()

        model.prefs.readingPane = true
        model.select(order[2])
        model.focusList()
        settle(window)
        shot("pane-focused")
        model.focus = .reader
        shot("pane-unfocused")
        model.prefs.readingPane = false
        model.focusList()

        let serverSearch = model.services.serverSearch
        model.services.serverSearch = { _ in 0 }
        // Few enough results to fit one page, so the Gmail footer ends the list; the last result is selected.
        model.searchText = "is:draft"
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        model.searchFieldFocused = false
        model.focusList()
        if let last = model.snapshot.order.last { model.select(last) }
        let footer = model.snapshot.items.count - 1
        list.table.scrollRowToVisible(footer)
        list.setFooterHovered(footer)
        shot("search")
        list.setFooterHovered(nil)
        model.endSearch(restoreFocus: true)
        model.services.serverSearch = serverSearch
        model.moveToTop()
        model.prefs.readingPane = readingPane
    }
}
