import AppKit
import SwiftUI
import TernCore

/// The message list: an AppKit table (cell reuse, fixed row heights, custom-drawn rows) inside SwiftUI.
struct MessageListView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> MessageListController { MessageListController(model: model) }
    func makeNSView(context: Context) -> NSScrollView { context.coordinator.scrollView }
    func updateNSView(_ nsView: NSScrollView, context: Context) {}
}

/// Owns the table, keeps it in step with `AppModel` (diffs, collapse animation, selection) and handles
/// mouse input: clicks, hover buttons, context menus and dragging rows onto the sidebar.
@MainActor
final class MessageListController: NSObject, NSTableViewDataSource, NSTableViewDelegate, ListPresenting {
    let model: AppModel
    let scrollView = NSScrollView()
    let table = MessageTableView()
    private var items: [ListItem] = []
    private var snapshot = ListSnapshot.empty
    private(set) var style: RowStyle = .twoLines
    private var hoveredRow: Int?
    private var footerHovered: Int?
    private let hoverBar: NSHostingView<RowHoverBar>
    private var lastWidth: CGFloat = 0
    /// True while a new list replaces the old one; scroll changes then aren't the user's.
    private var resetting = false

    static let headerHeight: CGFloat = 34
    static let footerHeight: CGFloat = 44

    init(model: AppModel) {
        self.model = model
        hoverBar = NSHostingView(rootView: RowHoverBar(model: model, keys: []))
        super.init()

        let column = NSTableColumn(identifier: .init("thread"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .plain
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .none
        table.intercellSpacing = .zero
        table.gridStyleMask = []
        table.usesAutomaticRowHeights = false
        table.rowSizeStyle = .custom
        table.floatsGroupRows = true
        table.allowsTypeSelect = false
        table.allowsEmptySelection = true
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.focusRingType = .none
        table.dataSource = self
        table.delegate = self
        table.controller = self

        scrollView.documentView = table
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 64, right: 0)
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(didScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.addObserver(self, selector: #selector(didResize), name: NSView.frameDidChangeNotification, object: scrollView)

        hoverBar.isHidden = true
        hoverBar.sizingOptions = []
        table.addSubview(hoverBar)

        model.listView = self
        observePreferences()
        listDidChange(model.snapshot, animation: .reset)
        selectionDidChange(scrollTo: nil)
    }

    // MARK: ListPresenting

    func listDidChange(_ snapshot: ListSnapshot, animation: ListAnimation) {
        // Clear hover while the old snapshot still matches the rows on screen.
        setHovered(nil)
        let old = items
        let new = snapshot.items
        self.snapshot = snapshot

        if animation == .reset || old.isEmpty {
            items = new
            resetting = true
            table.reloadData()
            table.scroll(.zero)
            resetting = false
            refreshVisibleRows()
            return
        }
        let diff = new.difference(from: old)
        guard !diff.isEmpty else {
            refreshVisibleRows()
            return
        }
        if diff.count > 80 {
            items = new
            table.reloadData()
            refreshVisibleRows()
            return
        }
        items = new
        let removals = diff.removals.map(Self.offset).sorted(by: >)
        let insertions = diff.insertions.map(Self.offset).sorted()
        let collapse = animation == .collapse && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup { context in
            context.duration = collapse ? 0.16 : 0
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            table.beginUpdates()
            for offset in removals {
                table.removeRows(at: IndexSet(integer: offset), withAnimation: collapse ? [.slideUp, .effectFade] : [])
            }
            for offset in insertions {
                table.insertRows(at: IndexSet(integer: offset), withAnimation: [])
            }
            table.endUpdates()
        }
        refreshVisibleRows()
    }

    private static func offset(_ change: CollectionDifference<ListItem>.Change) -> Int {
        switch change {
        case .insert(let offset, _, _), .remove(let offset, _, _): offset
        }
    }

    func takeKeyboard() {
        guard let window = table.window, window.firstResponder !== table else { return }
        window.makeFirstResponder(table)
    }

    func selectionDidChange(scrollTo key: ThreadKey?) {
        refreshVisibleRows()
        if let key, let index = snapshot.itemIndex[key] { reveal(index) }
    }

    /// Scrolls just enough to show the row below the sticky header, without animation (j/k speed).
    private func reveal(_ index: Int) {
        let rect = table.rect(ofRow: index)
        let visible = scrollView.contentView.bounds
        let top = visible.minY + Self.headerHeight
        let bottom = visible.maxY - scrollView.contentInsets.bottom
        var y = visible.minY
        if rect.minY < top { y = rect.minY - Self.headerHeight } else if rect.maxY > bottom { y = rect.maxY - visible.height + scrollView.contentInsets.bottom } else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, y)))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Re-applies models to every row view on screen (selection, hover, content).
    func refreshVisibleRows() {
        table.enumerateAvailableRowViews { rowView, row in
            if let view = rowView as? ThreadRowView { view.model = rowModel(row) }
            if let view = rowView as? ServerSearchRowView, items.indices.contains(row), case .serverSearch(let text) = items[row] {
                view.text = text
                view.isHovered = row == footerHovered
            }
        }
        updateHoverBar()
    }

    // MARK: Data source and delegate

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard items.indices.contains(row) else { return style.height }
        switch items[row] {
        case .header: return Self.headerHeight
        case .thread: return style.height
        case .serverSearch: return Self.footerHeight
        }
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard items.indices.contains(row), case .header = items[row] else { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { nil }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        guard items.indices.contains(row) else { return nil }
        switch items[row] {
        case .header(let title):
            let view = tableView.makeView(withIdentifier: .init("header"), owner: nil) as? HeaderRowView ?? HeaderRowView()
            view.identifier = .init("header")
            view.title = title
            return view
        case .thread:
            let view = tableView.makeView(withIdentifier: .init("thread"), owner: nil) as? ThreadRowView ?? ThreadRowView()
            view.identifier = .init("thread")
            view.model = rowModel(row)
            return view
        case .serverSearch(let text):
            let view = tableView.makeView(withIdentifier: .init("serverSearch"), owner: nil) as? ServerSearchRowView ?? ServerSearchRowView()
            view.identifier = .init("serverSearch")
            view.text = text
            view.isHovered = row == footerHovered
            return view
        }
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    private func rowModel(_ index: Int) -> RowModel? {
        guard let row = snapshot.row(at: index) else { return nil }
        let key = row.id
        let selected = model.isSelected(key)
        var result = RowModel(row: row, style: style)
        result.isSelected = selected
        // Offscreen renders (snapshots) draw the ring as if the window were key.
        let windowActive = table.window.map { $0.isKeyWindow || !$0.isVisible } ?? true
        result.hasFocusRing = key == model.cursor && model.focus == .list && windowActive && !model.searchFieldFocused
        result.isHovered = index == hoveredRow
        result.avatar = avatar(for: row)
        if row.needsReply, model.kind != .needsReply {
            result.chips.append(RowChip(text: "Needs reply", icon: .needsReply, tint: .ink))
        }
        if let project = row.projectIds.lazy.compactMap({ self.model.project($0) }).first {
            result.chips.append(RowChip(text: project.name, icon: Icon.project(project.icon), tint: .project(project.colorIndex)))
        } else if let category = row.category, category.showsChip {
            result.chips.append(RowChip(text: category.title, icon: Icon.category(category), tint: .category(category)))
        }
        if case .snoozed = model.kind, !model.isSearching, let until = row.snoozedUntil {
            result.timeOverride = SnoozeOption.detailText(until)
        }
        if model.prefs.dimReadByAge, row.thread.unreadCount == 0, row.thread.lastDate < Date().addingTimeInterval(-30 * 86_400) {
            result.dimmed = true
        }
        if model.isSearching { result.highlight = model.highlight(for: key) }
        return result
    }

    /// The sender's domain logo, else initials (in the account's hue when several accounts share the
    /// list). Asks for logos as rows come into view, except in Spam and Trash: fetching a logo tells the
    /// sender's domain this Mac's address, like a tracking pixel.
    private func avatar(for row: ThreadRow) -> RowAvatar {
        let thread = row.thread
        let sender = RowFormat.avatarParticipant(thread)
        let email = sender?.email ?? thread.accountId
        let logos = SenderLogos.shared
        if sender != nil {
            if !Self.isQuarantined(thread, in: model.kind) { logos.want(email) }
            if let image = logos.logo(forEmail: email) { return .logo(image) }
        }
        let tinted = model.scope == .all && model.accounts.count > 1 ? model.account(thread.accountId)?.colorIndex : nil
        let name = sender?.name ?? model.account(thread.accountId)?.displayName ?? ""
        return .letters(Avatar.initials(name: name, email: email), account: tinted)
    }

    private static func isQuarantined(_ thread: MailThread, in kind: Mailbox.Kind) -> Bool {
        kind == .spam || kind == .trash || thread.labelIds.contains(SystemLabel.spam) || thread.labelIds.contains(SystemLabel.trash)
    }

    // MARK: Width, density, preferences

    @objc private func didResize() {
        let width = scrollView.frame.width
        guard width != lastWidth else { return }
        lastWidth = width
        updateStyle()
    }

    /// Switches between one and two lines when the width or density preference crosses over.
    private func updateStyle() {
        let next = RowStyle.resolve(model.prefs.density, width: scrollView.frame.width)
        guard next != style else { return }
        style = next
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<items.count))
        refreshVisibleRows()
    }

    /// The focus ring follows the window's key state.
    func windowKeyChanged() {
        refreshVisibleRows()
    }

    private func observePreferences() {
        withObservationTracking {
            _ = model.prefs.density
            _ = model.prefs.dimReadByAge
            _ = model.projects
            _ = model.accounts
            _ = model.focus
            _ = model.searchFieldFocused
            // A logo arrived: refresh the rows on screen; only those whose picture changed redraw.
            _ = SenderLogos.shared.revision
        } onChange: { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.updateStyle()
                    self.refreshVisibleRows()
                    self.observePreferences()
                }
            }
        }
    }

    // MARK: Scrolling, paging, hover

    /// Reads the next page near the end, once the user has scrolled a row or more (or the rows don't fill the view):
    /// a fresh list jumping to the top must not cost a second read, e.g. on every search keystroke.
    @objc private func didScroll() {
        let bounds = scrollView.contentView.bounds
        let visible = table.rows(in: bounds)
        let nearEnd = visible.location + visible.length >= items.count - 30
        if !resetting, nearEnd, bounds.minY > style.height || table.frame.height <= bounds.height { model.loadMore() }
        updateHoverFromMouse()
    }

    func updateHoverFromMouse() {
        // A click-through window (offscreen renders) has no pointer over it.
        guard let window = table.window, window.isVisible, !window.ignoresMouseEvents else { return }
        let point = table.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let row = scrollView.contentView.bounds.contains(table.convert(point, to: scrollView.contentView)) ? table.row(at: point) : -1
        setHovered(row >= 0 && items.indices.contains(row) && items[row].threadKey != nil ? row : nil)
        let footer = row >= 0 && items.indices.contains(row) && isFooter(row) ? row : nil
        if footer != footerHovered {
            footerHovered = footer
            refreshVisibleRows()
        }
    }

    private func isFooter(_ row: Int) -> Bool {
        if case .serverSearch = items[row] { return true }
        return false
    }

    /// A click on the "Search older mail on Gmail" row.
    func clickedFooter(_ row: Int) -> Bool {
        guard items.indices.contains(row), isFooter(row) else { return false }
        model.searchOnServer()
        return true
    }

    func setHovered(_ row: Int?) {
        guard row != hoveredRow else { return }
        let previous = hoveredRow
        hoveredRow = row
        for index in [previous, row].compactMap({ $0 }) where items.indices.contains(index) {
            (table.rowView(atRow: index, makeIfNecessary: false) as? ThreadRowView)?.model = rowModel(index)
        }
        updateHoverBar()
    }

    private func updateHoverBar() {
        guard let row = hoveredRow, let key = items.indices.contains(row) ? items[row].threadKey : nil, !table.isDragging else {
            hoverBar.isHidden = true
            return
        }
        let rect = table.rect(ofRow: row)
        let column = ListLayout.column(in: rect)
        let size = CGSize(width: ThreadRowView.hoverWidth, height: 24)
        let centerY = style == .oneLine ? rect.midY : rect.minY + 18
        hoverBar.rootView = RowHoverBar(model: model, keys: targets(for: key))
        hoverBar.frame = CGRect(x: column.maxX - 4 - size.width, y: centerY - size.height / 2, width: size.width, height: size.height)
        // Row views are added after the bar; keep the bar on top of them.
        if table.subviews.last !== hoverBar { table.addSubview(hoverBar, positioned: .above, relativeTo: nil) }
        hoverBar.isHidden = false
    }

    /// A row action applies to the whole selection when the row is part of it.
    func targets(for key: ThreadKey) -> [ThreadKey] {
        model.checked.contains(key) ? model.targets : [key]
    }

    func key(atRow row: Int) -> ThreadKey? {
        items.indices.contains(row) ? items[row].threadKey : nil
    }

    // MARK: Menus

    /// Right-click or `…`: select the row (unless it is already part of the selection), then show every action.
    func actionMenu(forRow row: Int) -> NSMenu? {
        guard let key = key(atRow: row), let registry = model.registry else { return nil }
        if !model.isSelected(key) { model.select(key) }
        return ThreadMenu.make(registry: registry, model: model)
    }
}

/// The table: owns clicks so selection stays in `AppModel`, and starts drags onto the sidebar.
final class MessageTableView: NSTableView {
    weak var controller: MessageListController?
    private var mouseDownPoint: NSPoint?
    private var mouseDownRow = -1
    private var pendingClick: ThreadKey?
    private(set) var isDragging = false

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        guard let window else { return }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(keyStateChanged), name: name, object: window)
        }
    }

    @objc private func keyStateChanged() {
        MainActor.assumeIsolated { controller?.windowKeyChanged() }
    }

    override func becomeFirstResponder() -> Bool {
        MainActor.assumeIsolated { controller?.model.focus = .list }
        return super.becomeFirstResponder()
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        mouseDownPoint = point
        mouseDownRow = row
        pendingClick = nil
        MainActor.assumeIsolated {
            if controller?.clickedFooter(row) == true { return }
            guard let controller, let key = controller.key(atRow: row) else { return }
            let flags = event.modifierFlags
            if event.clickCount == 2 {
                controller.model.open()
                return
            }
            if flags.contains(.command) || flags.contains(.shift) {
                controller.model.click(key, command: flags.contains(.command), shift: flags.contains(.shift))
                return
            }
            // A plain click opens the row on mouse-up, so a drag can still carry the whole selection
            // and dragging a row doesn't open it.
            if !controller.model.checked.contains(key) { controller.model.select(key) }
            pendingClick = key
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !isDragging else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - start.x, point.y - start.y) > 4 else { return }
        MainActor.assumeIsolated {
            guard let controller, let key = controller.key(atRow: mouseDownRow) else { return }
            let keys = controller.targets(for: key)
            controller.model.draggedKeys = keys
            isDragging = true
            controller.setHovered(nil)
            let item = NSPasteboardItem()
            item.setString(keys.count == 1 ? "1 conversation" : "\(keys.count) conversations", forType: .string)
            let dragging = NSDraggingItem(pasteboardWriter: item)
            let image = DragBadge.image(count: keys.count, appearance: effectiveAppearance)
            dragging.setDraggingFrame(CGRect(origin: CGPoint(x: point.x - 12, y: point.y - image.size.height / 2), size: image.size), contents: image)
            beginDraggingSession(with: [dragging], event: event, source: self)
        }
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownPoint = nil
        guard let key = pendingClick, !isDragging else { return }
        pendingClick = nil
        MainActor.assumeIsolated { controller?.model.click(key, command: false, shift: false) }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        return MainActor.assumeIsolated { controller?.actionMenu(forRow: row) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.updateHoverFromMouse() }
    }

    override func mouseExited(with event: NSEvent) {
        MainActor.assumeIsolated { controller?.setHovered(nil) }
    }
}

extension MessageTableView {
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        mouseDownPoint = nil
        pendingClick = nil
        MainActor.assumeIsolated {
            if operation == [] { controller?.model.draggedKeys = [] }
            controller?.updateHoverFromMouse()
        }
    }
}

/// The badge that follows the pointer while dragging rows.
enum DragBadge {
    static func image(count: Int, appearance: NSAppearance) -> NSImage {
        let text = count == 1 ? "1 conversation" : "\(count) conversations"
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.ui(12, .medium), .foregroundColor: Theme.onInk]
        let size = (text as NSString).size(withAttributes: attributes)
        let image = NSImage(size: NSSize(width: ceil(size.width) + 24, height: 26))
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            Theme.ink.setFill()
            NSBezierPath(roundedRect: NSRect(origin: .zero, size: image.size), xRadius: Theme.Radius.control, yRadius: Theme.Radius.control).fill()
            (text as NSString).draw(at: NSPoint(x: 12, y: (26 - size.height) / 2), withAttributes: attributes)
        }
        image.unlockFocus()
        return image
    }
}
