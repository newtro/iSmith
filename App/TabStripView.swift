import AppKit
import Combine
import SwiftUI

/// The tab strip across the top of a window, for the space it shows: the space's name, its pinned
/// tabs, its tabs and group labels, and a "+" button. AppKit rather than SwiftUI, for drag and
/// drop: tabs drag within the strip, into and out of groups and the pinned tabs, onto a space in
/// the rail, into another window's strip or sidebar, or out of the window into a new one.
final class TabStripView: NSView {
    let browser: BrowserState
    let windowState: WindowState
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let scrollView = StripScrollView()
    let content: StripContentView
    private let plusButton = NSButton()

    init(browser: BrowserState, window: WindowState) {
        self.browser = browser
        windowState = window
        content = StripContentView(browser: browser, window: window, axis: .horizontal)
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        scrollView.drawsBackground = false
        // The window has a full-size content view; the strip must not be pushed below the title bar.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = content
        StripContentView.configurePlusButton(plusButton)
        plusButton.target = self
        plusButton.action = #selector(newTab)
        for view in [dot, nameLabel, scrollView, plusButton] { addSubview(view) }
        content.onChange = { [weak self] in self?.needsLayout = true }
        registerForDraggedTypes([.ismithTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var tabs: SpaceTabs? {
        get { content.tabs }
        set { if newValue !== content.tabs { content.tabs = newValue } }
    }

    func setSpace(name: String, color: NSColor) {
        if nameLabel.stringValue != name {
            nameLabel.stringValue = name
            needsLayout = true
        }
        dot.layer?.backgroundColor = color.cgColor
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 12
        dot.frame = NSRect(x: x, y: (h - 10) / 2, width: 10, height: 10)
        x += 17
        let nameWidth = min(ceil(nameLabel.attributedStringValue.size().width) + 6, 160)
        nameLabel.frame = NSRect(x: x, y: (h - nameLabel.intrinsicContentSize.height) / 2, width: nameWidth,
                                 height: nameLabel.intrinsicContentSize.height)
        x += nameWidth + 10
        let plus: CGFloat = 28
        let available = max(0, bounds.width - x - plus - 12)
        let width = content.layoutItems(maxWidth: available, height: h)
        let visible = min(width, available)
        scrollView.frame = NSRect(x: x, y: 0, width: visible, height: h)
        content.frame = NSRect(x: 0, y: 0, width: max(width, visible), height: h)
        plusButton.frame = NSRect(x: x + visible + 4, y: (h - plus) / 2, width: plus, height: plus)
        content.scrollSelectedIntoView()
    }

    @objc private func newTab() {
        browser.newTab(in: windowState)
    }

    // The whole strip takes tab drops, not just the tabs: dropping right of the last tab (or on a
    // space with no tabs yet) puts the tab at the end.
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { content.draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { content.draggingUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { content.draggingExited(sender) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { content.concludeDragOperation(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { content.performDragOperation(sender) }

    // The strip doubles as the title bar: drag empty space to move the window, double-click it for
    // a new tab.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { browser.newTab(in: windowState) } else { window?.performDrag(with: event) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// Turns a vertical scroll wheel into horizontal scrolling when the tabs overflow.
final class StripScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX) else { return super.scrollWheel(with: event) }
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY : event.scrollingDeltaY * 16
        let maxX = max(0, (documentView?.frame.width ?? 0) - contentView.bounds.width)
        var origin = contentView.bounds.origin
        origin.x = min(max(0, origin.x - delta), maxX)
        contentView.scroll(to: origin)
        reflectScrolledClipView(contentView)
    }
}

/// Where a dropped tab goes: before which tab (nil: the end), in which group, pinned or not, and
/// where the insertion marker is drawn.
struct TabDropTarget: Equatable {
    var before: UUID?
    var group: UUID?
    var pinned = false
    var marker: NSRect
}

/// The pinned tabs, tabs and group labels, laid out left to right (the strip) or top to bottom
/// (the sidebar, with the pinned tabs as a grid of icons on top). Also the drop target for tabs.
final class StripContentView: NSView {
    enum Axis { case horizontal, vertical }

    let browser: BrowserState
    let windowState: WindowState
    let axis: Axis
    var onChange: (() -> Void)?
    private var tabViews: [UUID: TabItemView] = [:]
    private var chipViews: [UUID: GroupChipView] = [:]
    /// What's shown, in order.
    private(set) var ordered: [NSView] = []
    private let indicator = NSView()
    private var subscriptions: [AnyCancellable] = []
    private var reloadScheduled = false
    /// A group just created from a menu: its editor opens once its label is on screen.
    var pendingEdit: UUID?
    private var popover: NSPopover?
    /// The tab being dragged over this view, dimmed until the drag leaves or ends.
    private weak var dimmed: TabItemView?

    static let gap: CGFloat = 4
    static let maxTab: CGFloat = 200
    static let minTab: CGFloat = 110
    static let pinnedSize = NSSize(width: 34, height: 30)
    /// The sidebar's margins and row heights.
    static let sideInset: CGFloat = 8
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 26

    init(browser: BrowserState, window: WindowState, axis: Axis) {
        self.browser = browser
        windowState = window
        self.axis = axis
        super.init(frame: .zero)
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1.5
        indicator.isHidden = true
        addSubview(indicator)
        registerForDraggedTypes([.ismithTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var tabs: SpaceTabs? {
        didSet {
            subscriptions = []
            if let tabs {
                subscriptions.append(tabs.objectWillChange.sink { [weak self] _ in self?.scheduleReload() })
            }
            reload()
        }
    }

    static func configurePlusButton(_ button: NSButton) {
        button.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = "New tab  ⌘T"
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    /// Matches the views to the layout, reusing each tab's and group's view.
    func reload() {
        guard let tabs else {
            ordered.forEach { $0.removeFromSuperview() }
            ordered = []
            tabViews = [:]
            chipViews = [:]
            onChange?()
            return
        }
        let layout = tabs.layout
        let picked = tabs.selection.marked
        var views: [NSView] = []
        var usedTabs = Set<UUID>()
        var usedChips = Set<UUID>()
        func tabView(_ id: UUID, group: TabGroup?, pinned: Bool) {
            guard let tab = tabs.tab(id) else { return }
            let mode: TabItemView.Mode = pinned ? .pinned : axis == .horizontal ? .tab : .row
            let view = tabViews[id].flatMap { $0.tab === tab ? $0 : nil } ?? TabItemView(tab: tab, strip: self)
            tabViews[id] = view
            view.configure(group: group, mode: mode, selected: layout.selected == id, marked: picked.contains(id))
            usedTabs.insert(id)
            views.append(view)
        }
        for item in layout.items {
            switch item {
            case let .pinned(id):
                tabView(id, group: nil, pinned: true)
            case let .group(group, count):
                let view = chipViews[group.id] ?? GroupChipView(strip: self)
                chipViews[group.id] = view
                view.configure(group: group, count: count)
                usedChips.insert(group.id)
                views.append(view)
            case let .tab(id, group):
                tabView(id, group: group, pinned: false)
            }
        }
        for (id, view) in tabViews where !usedTabs.contains(id) {
            view.removeFromSuperview()
            tabViews[id] = nil
        }
        for (id, view) in chipViews where !usedChips.contains(id) {
            view.removeFromSuperview()
            chipViews[id] = nil
        }
        for view in views where view.superview !== self { addSubview(view, positioned: .below, relativeTo: indicator) }
        ordered = views
        onChange?()
        if let pending = pendingEdit, let chip = chipViews[pending] {
            pendingEdit = nil
            DispatchQueue.main.async { [weak self] in self?.editGroup(pending, from: chip) }
        }
    }

    private var pinnedViews: [TabItemView] {
        ordered.compactMap { ($0 as? TabItemView).flatMap { $0.mode == .pinned ? $0 : nil } }
    }

    /// Sizes and places every item across; returns the width they need. Pinned tabs are icons;
    /// tabs share the rest between `minTab` and `maxTab` wide; past that the strip scrolls.
    func layoutItems(maxWidth: CGFloat, height: CGFloat) -> CGFloat {
        let chips = ordered.compactMap { $0 as? GroupChipView }
        let pinned = pinnedViews
        let chipWidth = chips.reduce(0) { $0 + $1.preferredWidth + Self.gap }
        let pinnedWidth = pinned.reduce(0) { x, _ in x + Self.pinnedSize.width + Self.gap }
        let tabCount = ordered.count - chips.count - pinned.count
        let gaps = Self.gap * CGFloat(max(0, ordered.count - 1))
        let tabWidth = tabCount == 0 ? 0
            : min(Self.maxTab, max(Self.minTab, floor((maxWidth - chipWidth - pinnedWidth - gaps) / CGFloat(tabCount))))
        var x: CGFloat = 0
        for view in ordered {
            if let chip = view as? GroupChipView {
                if x > 0 { x += Self.gap }
                chip.frame = NSRect(x: x, y: (height - 22) / 2, width: chip.preferredWidth, height: 22)
                x += chip.preferredWidth + Self.gap
            } else if let tab = view as? TabItemView, tab.mode == .pinned {
                tab.frame = NSRect(x: x, y: (height - Self.pinnedSize.height) / 2, width: Self.pinnedSize.width,
                                   height: Self.pinnedSize.height)
                x += Self.pinnedSize.width + Self.gap
                // A little more room between the pinned tabs and the rest.
                if tab === pinned.last, tabCount + chips.count > 0 { x += 4 }
            } else {
                view.frame = NSRect(x: x, y: (height - 30) / 2, width: tabWidth, height: 30)
                x += tabWidth + Self.gap
            }
        }
        return max(0, x - Self.gap)
    }

    /// Places every item down the sidebar `width` wide; returns the height they need. Pinned tabs
    /// are a grid of icons on top, then group headers and tab rows (a group's tabs indented).
    func layoutRows(width: CGFloat) -> CGFloat {
        let inset = Self.sideInset
        let pinned = pinnedViews
        var y: CGFloat = 4
        if !pinned.isEmpty {
            let tile = NSSize(width: 36, height: 32)
            let columns = max(1, Int((width - 2 * inset + Self.gap) / (tile.width + Self.gap)))
            for (i, view) in pinned.enumerated() {
                let row = i / columns, column = i % columns
                view.frame = NSRect(x: inset + CGFloat(column) * (tile.width + Self.gap),
                                    y: y + CGFloat(row) * (tile.height + Self.gap), width: tile.width, height: tile.height)
            }
            let rows = (pinned.count + columns - 1) / columns
            y += CGFloat(rows) * (tile.height + Self.gap) + 6
        }
        for view in ordered {
            if let chip = view as? GroupChipView {
                y += 4
                chip.frame = NSRect(x: inset, y: y, width: width - 2 * inset, height: Self.headerHeight)
                y += Self.headerHeight + 2
            } else if let tab = view as? TabItemView, tab.mode != .pinned {
                let indent: CGFloat = tab.group == nil ? 0 : 10
                tab.frame = NSRect(x: inset + indent, y: y, width: width - 2 * inset - indent, height: Self.rowHeight)
                y += Self.rowHeight + 2
            }
        }
        return y + 4
    }

    /// VoiceOver reads the strip in order, whatever order the views were added in.
    override func accessibilityChildren() -> [Any]? { ordered }

    func scrollSelectedIntoView() {
        guard let id = tabs?.layout.selected, let view = tabViews[id] else { return }
        scrollToVisible(axis == .horizontal ? view.frame.insetBy(dx: -8, dy: 0) : view.frame.insetBy(dx: 0, dy: -8))
    }

    func view(for id: UUID) -> TabItemView? { tabViews[id] }

    /// After a click on a tab or a group label: if AppKit took the keyboard away from everything
    /// (a refused first responder leaves it with the window), it goes to the page on screen.
    func keepPageFocus() {
        guard let window else { return }
        DispatchQueue.main.async { [weak self, weak window] in
            guard let window, window.firstResponder === window || window.firstResponder == nil,
                  let webView = self?.tabs?.selected?.webView, webView.window === window else { return }
            window.makeFirstResponder(webView)
        }
    }

    // MARK: - Dropping tabs

    private func marker(at position: CGFloat) -> NSRect {
        axis == .horizontal
            ? NSRect(x: max(0, position - 1.5), y: 4, width: 3, height: max(0, bounds.height - 8))
            : NSRect(x: Self.sideInset, y: max(0, position - 1.5), width: max(0, bounds.width - 2 * Self.sideInset), height: 3)
    }

    /// Where a tab dropped at `point` goes. Over a pinned tab: before it (left half) or after it,
    /// pinned. Over a tab: before or after it (by halves), in that tab's group. Over an expanded
    /// group's label: its leading 30% drops before the group, the rest into it, first. A collapsed
    /// group is one item. Anywhere past the end: the end, ungrouped.
    func dropTarget(at point: NSPoint) -> TabDropTarget {
        let end = TabDropTarget(before: nil, group: nil, pinned: false,
                                marker: marker(at: axis == .horizontal ? (ordered.last?.frame.maxX ?? 0) + 2 : (ordered.last?.frame.maxY ?? 0) + 1))
        guard let layout = tabs?.layout else { return end }
        let ids = layout.ids
        func after(_ id: UUID) -> UUID? {
            guard let i = ids.firstIndex(of: id), i + 1 < ids.count else { return nil }
            return ids[i + 1]
        }
        let horizontal = axis == .horizontal
        let half = Self.gap / 2
        // The pinned tabs.
        let pinned = pinnedViews
        if let last = pinned.last {
            let inPinned = horizontal ? point.x < last.frame.maxX + half : point.y < last.frame.maxY + half
            if inPinned {
                for (i, view) in pinned.enumerated() {
                    let f = view.frame
                    if !horizontal {
                        guard point.y >= f.minY - half - 2, point.y < f.maxY + half else { continue }
                        let lastInRow = i + 1 == pinned.count || pinned[i + 1].frame.minY > f.minY
                        guard point.x < f.maxX + half || lastInRow else { continue }
                    } else if point.x >= f.maxX + half {
                        continue
                    }
                    let bar = { (x: CGFloat) in
                        horizontal ? self.marker(at: x) : NSRect(x: x - 1.5, y: f.minY, width: 3, height: f.height)
                    }
                    return point.x < f.midX
                        ? TabDropTarget(before: view.tab.id, group: nil, pinned: true, marker: bar(f.minX - 2))
                        : TabDropTarget(before: after(view.tab.id), group: nil, pinned: true, marker: bar(f.maxX + 2))
                }
                return TabDropTarget(before: after(last.tab.id), group: nil, pinned: true, marker: marker(at: horizontal ? last.frame.maxX + 2 : last.frame.maxY + 1))
            }
        }
        for view in ordered {
            if let tab = view as? TabItemView, tab.mode == .pinned { continue }
            let f = view.frame
            let (position, low, high, mid) = horizontal ? (point.x, f.minX, f.maxX, f.midX) : (point.y, f.minY, f.maxY, f.midY)
            guard position < high + half else { continue }
            let before = marker(at: low - (horizontal ? 2 : 1)), afterBar = marker(at: high + (horizontal ? 2 : 1))
            if let tabView = view as? TabItemView {
                let group = layout.groupID(of: tabView.tab.id)
                return position < mid
                    ? TabDropTarget(before: tabView.tab.id, group: group, marker: before)
                    : TabDropTarget(before: after(tabView.tab.id), group: group, marker: afterBar)
            }
            if let chip = view as? GroupChipView {
                let members = layout.tabs(in: chip.group.id)
                if chip.group.collapsed {
                    // A collapsed group is one item: drop before or after it.
                    return position < mid
                        ? TabDropTarget(before: members.first, group: nil, marker: before)
                        : TabDropTarget(before: members.last.flatMap(after), group: nil, marker: afterBar)
                }
                return position < low + (high - low) * 0.3
                    ? TabDropTarget(before: members.first, group: nil, marker: before)
                    : TabDropTarget(before: members.first, group: chip.group.id, marker: afterBar)
            }
        }
        return end
    }

    /// The insertion marker: a bar in the accent color (or the group's, for a drop into a group)
    /// where the tab will land. The dragged tab itself is dimmed meanwhile.
    private func showIndicator(_ target: TabDropTarget) {
        let color = target.group.flatMap { tabs?.layout.group($0)?.color.nsColor } ?? .controlAccentColor
        indicator.layer?.backgroundColor = color.cgColor
        indicator.frame = target.marker
        indicator.isHidden = false
        if case let .tab(id, _, _) = browser.drag, let view = tabViews[id] {
            if dimmed !== view { dimmed?.alphaValue = 1 }
            dimmed = view
            view.alphaValue = 0.45
        }
    }

    private func hideIndicator() {
        indicator.isHidden = true
        dimmed?.alphaValue = 1
        dimmed = nil
    }

    /// Whether the insertion marker is showing, and where (for tests).
    var indicatorFrame: NSRect? { indicator.isHidden ? nil : indicator.frame }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .tab = browser.drag, tabs != nil else {
            hideIndicator()
            return []
        }
        showIndicator(dropTarget(at: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hideIndicator()
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        hideIndicator()
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        hideIndicator()
        guard case let .tab(id, windowID, spaceID) = browser.drag, let tabs,
              let source = browser.windows.first(where: { $0.id == windowID }) else { return false }
        let target = dropTarget(at: convert(sender.draggingLocation, from: nil))
        browser.moveTab(id, from: (source, spaceID), to: (windowState, tabs.spaceID), before: target.before,
                        group: target.group, pinned: target.pinned)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        superview?.superview?.superview?.mouseDown(with: event) // the strip or sidebar: window drag or new tab
    }

    // MARK: - Menus

    func menu(forTab id: UUID) -> NSMenu? {
        guard let tabs else { return nil }
        return TabMenu.make(for: id, tabs: tabs, browser: browser, window: windowState) { [weak self] group in
            self?.pendingEdit = group
        }
    }

    func menu(forGroup id: UUID, from chip: GroupChipView) -> NSMenu? {
        guard let tabs, let group = tabs.layout.group(id) else { return nil }
        let browser = browser
        let window = windowState
        let menu = NSMenu()
        menu.addItem(ActionItem("Edit Group…") { [weak self, weak chip] in
            if let chip { self?.editGroup(id, from: chip) }
        })
        let colors = NSMenu()
        for color in GroupColor.allCases {
            let item = ActionItem(color.title) { tabs.update { $0.setColor(id, color) } }
            item.image = Self.swatch(color.nsColor)
            item.state = group.color == color ? .on : .off
            colors.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        colorItem.submenu = colors
        menu.addItem(colorItem)
        menu.addItem(ActionItem(group.collapsed ? "Expand Group" : "Collapse Group") {
            browser.toggleCollapsed(id, in: tabs, window: window)
        })
        menu.addItem(.separator())
        menu.addItem(ActionItem("New Tab in Group") { browser.newTab(inGroup: id, tabs: tabs, window: window) })
        menu.addItem(ActionItem("Sort Group's Tabs by Site") { browser.sortBySite(tabs.layout.tabs(in: id), in: tabs) })
        let otherSpaces = browser.spaces.filter { $0.id != tabs.spaceID }
        if !otherSpaces.isEmpty {
            let sub = NSMenu()
            for space in otherSpaces {
                let item = ActionItem(space.def.name) {
                    browser.moveTabs(tabs.layout.tabs(in: id), from: tabs, in: window, toSpace: space.id)
                }
                item.image = Self.swatch(Palette.nsColor(space.def.color))
                sub.addItem(item)
            }
            let item = NSMenuItem(title: "Move Group's Tabs to Space", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Ungroup") { tabs.update { $0.ungroup(id) } })
        menu.addItem(ActionItem("Close Group") { browser.closeGroup(id, in: tabs) })
        return menu
    }

    /// The group's name and color, in a popover under (or beside) its label.
    func editGroup(_ id: UUID, from chip: GroupChipView) {
        guard let tabs, let group = tabs.layout.group(id), chip.window != nil else { return }
        popover?.close()
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: GroupEditor(
            name: group.name, color: group.color,
            apply: { name, color in
                tabs.update {
                    $0.rename(id, to: name)
                    $0.setColor(id, color)
                }
            },
            done: { [weak popover] in popover?.close() }))
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: axis == .horizontal ? .maxY : .maxX)
        self.popover = popover
    }

    static func swatch(_ color: NSColor) -> NSImage {
        NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            color.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3).fill()
            return true
        }
    }
}

/// A tab's context menu, for the strip, the sidebar and the tab overview. Its actions apply to
/// the selection when the tab is part of it (see `TabSelection`), otherwise to the tab alone.
@MainActor
enum TabMenu {
    /// `groupMade` is told about a group made from the menu (the strip opens its editor).
    static func make(for id: UUID, tabs: SpaceTabs, browser: BrowserState, window: WindowState,
                     groupMade: ((UUID) -> Void)? = nil) -> NSMenu? {
        guard let tab = tabs.tab(id) else { return nil }
        let targets = tabs.targets(for: id)
        return make(targets: targets, clicked: tab, tabs: tabs, browser: browser, window: window, groupMade: groupMade)
    }

    static func make(targets: [UUID], clicked tab: Tab?, tabs: SpaceTabs, browser: BrowserState, window: WindowState,
                     groupMade: ((UUID) -> Void)? = nil) -> NSMenu? {
        guard !targets.isEmpty else { return nil }
        let many = targets.count > 1
        let noun = many ? "\(targets.count) Tabs" : "Tab"
        let layout = tabs.layout
        let menu = NSMenu()
        if !many, let id = targets.first {
            menu.addItem(ActionItem("New Tab to the Right") { browser.newTab(after: id, in: tabs, window: window) })
            menu.addItem(.separator())
        }
        menu.addItem(ActionItem(many ? "Reload \(noun)" : "Reload") {
            for id in targets { if let t = tabs.tab(id) { browser.reload(t, in: tabs) } }
        })
        menu.addItem(ActionItem(many ? "Duplicate \(noun)" : "Duplicate") { browser.duplicate(targets, in: tabs, window: window) })
        if targets.allSatisfy(layout.isPinned) {
            menu.addItem(ActionItem("Unpin \(noun)") { browser.unpin(targets, in: tabs) })
        } else if !targets.contains(where: { layout.group(of: $0)?.agent == true }) {
            // An agent's tab is pinned again when it's taken back, not while the agent has it.
            menu.addItem(ActionItem("Pin \(noun)") { browser.pin(targets, in: tabs) })
        }
        if !many, let tab {
            let keepAlive = ActionItem(tab.keepAliveSetting == nil && tab.keepAlive ? "Keep Alive (automatic for this site)" : "Keep Alive") {
                browser.setKeepAlive(!tab.keepAlive, for: tab, in: tabs)
            }
            keepAlive.state = tab.keepAlive ? .on : .off
            keepAlive.toolTip = "Never unloaded or throttled in the background, so mail counts update and calls ring."
            menu.addItem(keepAlive)
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Add \(noun) to New Group") {
            if let group = browser.createGroup(with: targets, in: tabs) { groupMade?(group) }
        })
        // The Agent group only takes tabs an agent opens or acts on.
        let others = layout.groups.filter { g in !g.agent && !targets.allSatisfy { layout.groupID(of: $0) == g.id } }
        if !others.isEmpty {
            let sub = NSMenu()
            for group in others {
                let item = ActionItem(group.name.isEmpty ? "Unnamed group" : group.name) {
                    browser.move(targets, toGroup: group.id, in: tabs)
                }
                item.image = StripContentView.swatch(group.color.nsColor)
                sub.addItem(item)
            }
            let item = NSMenuItem(title: "Add \(noun) to Group", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        if targets.contains(where: { layout.group(of: $0)?.agent == true }) {
            // The agent may still read the tab, but no longer acts in it.
            let item = ActionItem("Take \(noun) Back from the Agent") {
                tabs.update { $0.removeFromGroup(targets) }
                tabs.marked = []
            }
            item.toolTip = "Moves the tab out of the Agent group: the agent stops acting in it, and password autofill works again."
            menu.addItem(item)
        } else if targets.contains(where: { layout.groupID(of: $0) != nil }) {
            menu.addItem(ActionItem("Remove \(noun) from Group") {
                tabs.update { $0.removeFromGroup(targets) }
                tabs.marked = []
            })
        }
        menu.addItem(.separator())
        let otherSpaces = browser.spaces.filter { $0.id != tabs.spaceID }
        if !otherSpaces.isEmpty {
            let sub = NSMenu()
            for space in otherSpaces {
                let item = ActionItem(space.def.name) { browser.moveTabs(targets, from: tabs, in: window, toSpace: space.id) }
                item.image = StripContentView.swatch(Palette.nsColor(space.def.color))
                sub.addItem(item)
            }
            let item = NSMenuItem(title: "Move \(noun) to Space", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        menu.addItem(ActionItem("Move \(noun) to New Window") { browser.moveToNewWindow(targets, from: tabs, in: window) })
        menu.addItem(.separator())
        if browser.data != nil {
            let bookmark = ActionItem(many ? "Bookmark \(noun) in a Folder" : "Bookmark Tab") { browser.bookmarkAll(targets, in: tabs) }
            bookmark.toolTip = many ? "Adds a folder of these tabs to Other Bookmarks." : "Adds the tab to the bookmarks bar."
            menu.addItem(bookmark)
        }
        menu.addItem(ActionItem(many ? "Sort \(noun) by Site" : "Sort Tabs by Site") { browser.sortBySite(targets, in: tabs) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Close \(noun)") { browser.closeTabs(targets, in: tabs) })
        if !layout.others(than: targets).isEmpty {
            menu.addItem(ActionItem("Close Other Tabs") { browser.closeOthers(than: targets, in: tabs) })
        }
        if !layout.tabsRight(of: targets).isEmpty {
            menu.addItem(ActionItem("Close Tabs to the Right") { browser.closeTabsRight(of: targets, in: tabs) })
        }
        return menu
    }
}

/// One tab: in the strip (icon, title, close button, the group's color along its bottom edge),
/// as a row in the sidebar (the group's color down its left edge), or pinned (the icon alone,
/// with the page's unread count).
///
/// An `NSControl`, not a plain view, because the strip sits in the window's title bar (the window
/// has a full-size content view): there, AppKit hands a drag to the window server as a window
/// move unless the view under the mouse is a control. A plain view doesn't stop it, even with
/// `mouseDownCanMoveWindow` false, so dragging a tab moved the window. Empty strip space is still a
/// plain view, so it still moves the window.
final class TabItemView: NSControl, NSDraggingSource {
    enum Mode { case tab, row, pinned }

    let tab: Tab
    private weak var strip: StripContentView?
    private(set) var group: TabGroup?
    private(set) var mode: Mode = .tab
    private var isSelected = false
    private var isMarked = false
    private var hovering = false
    private let titleField = NSTextField(labelWithString: "")
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let keepAliveIcon = NSImageView()
    private let badge = NSTextField(labelWithString: "")
    private let closeButton = NSButton()
    private let groupLine = CALayer()
    private var subscriptions: Set<AnyCancellable> = []
    private var mouseDownEvent: NSEvent?
    /// The view a drag started from, kept alive until the drag ends even if the strip drops it.
    private static var dragging: TabItemView?

    init(tab: Tab, strip: StripContentView) {
        self.tab = tab
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.addSublayer(groupLine)
        titleField.font = .systemFont(ofSize: 12)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.truncatesLastVisibleLine = true
        iconView.imageScaling = .scaleProportionallyUpOrDown
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        keepAliveIcon.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Keep alive")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        keepAliveIcon.contentTintColor = .secondaryLabelColor
        keepAliveIcon.toolTip = "Kept alive in the background"
        badge.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .semibold)
        badge.textColor = .white
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 6.5
        badge.layer?.backgroundColor = NSColor.systemRed.cgColor
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close tab  ⌘W"
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        for view in [iconView, spinner, keepAliveIcon, titleField, badge, closeButton] { addSubview(view) }
        tab.$title.sink { [weak self] title in
            self?.titleField.stringValue = title
            self?.updateBadge(title)
            self?.toolTip = title
        }.store(in: &subscriptions)
        tab.$isLoading.sink { [weak self] loading in
            if loading { self?.spinner.startAnimation(nil) } else { self?.spinner.stopAnimation(nil) }
            self?.needsLayout = true
        }.store(in: &subscriptions)
        tab.$keepAliveSetting.combineLatest(tab.$url).sink { [weak self] _, _ in
            DispatchQueue.main.async {
                self?.needsLayout = true
                self?.updateIcon()
            }
        }.store(in: &subscriptions)
        Favicons.shared.$generation.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateIcon() }
        }.store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A tab never holds the keyboard: a click leaves it with the page (see `keepPageFocus`). It
    /// still says it accepts first responder, because AppKit only treats an enabled control that
    /// does as blocking window moves in the title bar.
    override func becomeFirstResponder() -> Bool { false }

    private func updateIcon() {
        iconView.image = Favicons.shared.image(for: tab)
    }

    private func updateBadge(_ title: String) {
        let count = UnreadBadge.count(in: title) ?? 0
        badge.stringValue = count > 99 ? "99+" : "\(count)"
        badge.isHidden = mode != .pinned || count == 0
        needsLayout = true
    }

    func configure(group: TabGroup?, mode: Mode, selected: Bool, marked: Bool) {
        self.group = group
        let modeChanged = self.mode != mode
        self.mode = mode
        isSelected = selected
        isMarked = marked
        if modeChanged { updateBadge(tab.title) }
        needsDisplay = true
        needsLayout = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(selected)
    }

    override func accessibilityLabel() -> String? {
        tab.title + (mode == .pinned ? ", pinned" : "") + (tab.keepAlive ? ", kept alive" : "")
            + (group.map { ", in group \($0.name)" } ?? "") + (isMarked ? ", picked" : "")
    }

    override func accessibilityChildren() -> [Any]? { mode == .pinned ? [] : [closeButton] }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = strip?.menu(forTab: tab.id) else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: 0), in: self)
        return true
    }

    /// VoiceOver (and the smoke test) select a tab by pressing it.
    override func accessibilityPerformPress() -> Bool {
        guard let strip, let tabs = strip.tabs else { return false }
        strip.browser.selectTab(tab.id, in: tabs)
        return true
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if mode == .pinned {
            titleField.isHidden = true
            closeButton.isHidden = true
            keepAliveIcon.isHidden = true
            let icon = NSRect(x: (bounds.width - 16) / 2, y: (h - 16) / 2, width: 16, height: 16)
            iconView.frame = icon
            spinner.frame = icon
            iconView.isHidden = tab.isLoading
            let width = max(13, ceil(badge.attributedStringValue.size().width) + 7)
            badge.frame = NSRect(x: bounds.width - width - 1, y: h - 14, width: width, height: 13)
            groupLine.isHidden = true
            return
        }
        badge.isHidden = true
        titleField.isHidden = false
        var x: CGFloat = mode == .row ? 9 : 10
        let icon = NSRect(x: x, y: (h - 16) / 2, width: 16, height: 16)
        iconView.frame = icon
        spinner.frame = icon
        iconView.isHidden = tab.isLoading
        x += 21
        keepAliveIcon.isHidden = !tab.keepAlive
        if tab.keepAlive {
            keepAliveIcon.frame = NSRect(x: x - 2, y: (h - 12) / 2, width: 10, height: 12)
            x += 11
        }
        let showClose = isSelected || hovering
        closeButton.isHidden = !showClose
        closeButton.frame = NSRect(x: bounds.width - 24, y: (h - 16) / 2, width: 16, height: 16)
        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(x: x, y: (h - titleHeight) / 2, width: max(0, bounds.width - x - 28), height: titleHeight)
        groupLine.frame = mode == .row
            ? NSRect(x: 0, y: 6, width: 2.5, height: max(0, h - 12))
            : NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: 2.5)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let background: NSColor
            if isSelected {
                background = .textBackgroundColor
            } else if isMarked {
                background = NSColor.controlAccentColor.withAlphaComponent(0.2)
            } else if hovering {
                background = NSColor.labelColor.withAlphaComponent(0.07)
            } else if mode == .pinned {
                background = NSColor.labelColor.withAlphaComponent(0.04)
            } else {
                background = .clear
            }
            layer?.backgroundColor = background.cgColor
            layer?.borderWidth = isSelected || (isMarked && mode == .pinned) ? 1 : 0
            layer?.borderColor = (isMarked && !isSelected ? NSColor.controlAccentColor.withAlphaComponent(0.6) : NSColor.separatorColor).cgColor
            layer?.shadowOpacity = isSelected ? 0.08 : 0
            layer?.shadowRadius = 2
            layer?.shadowOffset = NSSize(width: 0, height: -1)
            groupLine.backgroundColor = group?.color.nsColor.cgColor
            groupLine.isHidden = group == nil || mode == .pinned
            titleField.textColor = isSelected ? .labelColor : .secondaryLabelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    private func setHover(_ on: Bool) {
        hovering = on
        needsDisplay = true
        needsLayout = true
    }

    // MARK: - Clicks

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        guard let strip, let tabs = strip.tabs else { return }
        let flags = event.modifierFlags
        let kind: TabSelection.Click = flags.contains(.command)
            ? (flags.contains(.shift) ? .commandShift : .command)
            : (flags.contains(.shift) ? .shift : .plain)
        if let select = tabs.click(tab.id, kind) { strip.browser.selectTab(select, in: tabs) }
        strip.keepPageFocus()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let down = mouseDownEvent else { return }
        let a = down.locationInWindow
        let b = event.locationInWindow
        guard hypot(a.x - b.x, a.y - b.y) > 4 else { return }
        mouseDownEvent = nil
        startDrag(down)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    override func otherMouseUp(with event: NSEvent) {
        if event.buttonNumber == 2 { closeTab() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.menu(forTab: tab.id)
    }

    @objc private func closeTab() {
        guard let strip, let tabs = strip.tabs else { return }
        strip.browser.closeTab(tab.id, in: tabs)
    }

    // MARK: - Dragging

    private func startDrag(_ event: NSEvent) {
        guard let strip, let tabs = strip.tabs else { return }
        strip.browser.drag = .tab(tab.id, window: strip.windowState.id, space: tabs.spaceID)
        let item = NSPasteboardItem()
        item.setString(tab.id.uuidString, forType: .ismithTab)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        dragging.setDraggingFrame(bounds, contents: snapshot())
        Self.dragging = self
        beginDraggingSession(with: [dragging], event: event, source: self)
    }

    private func snapshot() -> NSImage {
        let size = bounds.size
        return NSImage(size: size, flipped: false) { [weak self] _ in
            guard let self, let context = NSGraphicsContext.current?.cgContext, let layer = self.layer else { return false }
            layer.render(in: context)
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// A tab dropped outside every iSmith window opens in a new window there.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        defer { Self.dragging = nil }
        alphaValue = 1
        guard let strip else { return }
        let browser = strip.browser
        let drag = browser.drag
        browser.drag = nil
        guard operation == [], case let .tab(id, windowID, spaceID) = drag,
              let window = browser.windows.first(where: { $0.id == windowID }),
              let tabs = window.spaces[spaceID] else { return }
        let inside = NSApp.windows.contains { $0.isVisible && $0.frame.contains(screenPoint) }
        if !inside { browser.moveToNewWindow(id, from: tabs, in: window, at: screenPoint) }
    }
}

/// A group's label: its name on its color, and the tab count when collapsed. In the sidebar it's
/// a section header with a disclosure chevron. Click to collapse or expand; right-click to
/// rename, recolor, ungroup or close. A control for the same reason as `TabItemView`: in the title
/// bar only a control keeps a drag from moving the window.
final class GroupChipView: NSControl {
    private weak var strip: StripContentView?
    private(set) var group = TabGroup(name: "", color: .grey)
    private var count = 0
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()

    init(strip: StripContentView) {
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        chevron.contentTintColor = .secondaryLabelColor
        addSubview(label)
        addSubview(chevron)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func becomeFirstResponder() -> Bool { false }

    private var vertical: Bool { strip?.axis == .vertical }

    func configure(group: TabGroup, count: Int) {
        self.group = group
        self.count = count
        let text = NSMutableAttributedString()
        if group.agent, let image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Agent") {
            let attachment = NSTextAttachment()
            attachment.image = image.withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
            text.append(NSAttributedString(attachment: attachment))
            text.append(NSAttributedString(string: " "))
        }
        text.append(NSAttributedString(string: group.name, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)]))
        if group.collapsed || vertical {
            text.append(NSAttributedString(string: (group.name.isEmpty ? "" : "  ") + "\(count)",
                                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]))
        }
        label.attributedStringValue = text
        chevron.image = NSImage(systemSymbolName: group.collapsed ? "chevron.right" : "chevron.down", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        chevron.isHidden = !vertical
        toolTip = (group.collapsed ? "Expand " : "Collapse ") + (group.name.isEmpty ? "group" : group.name)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Group \(group.name), \(count) tabs, \(group.collapsed ? "collapsed" : "expanded")")
        needsDisplay = true
        needsLayout = true
    }

    override func accessibilityChildren() -> [Any]? { [] }

    override func accessibilityPerformPress() -> Bool {
        guard let strip, let tabs = strip.tabs else { return false }
        strip.browser.toggleCollapsed(group.id, in: tabs, window: strip.windowState)
        return true
    }

    override func accessibilityPerformShowMenu() -> Bool {
        guard let menu = strip?.menu(forGroup: group.id, from: self) else { return false }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
        return true
    }

    var preferredWidth: CGFloat {
        label.attributedStringValue.length == 0 ? 18 : min(180, ceil(label.attributedStringValue.size().width) + 22)
    }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        if vertical {
            chevron.frame = NSRect(x: 8, y: (bounds.height - 12) / 2, width: 12, height: 12)
            label.frame = NSRect(x: 25, y: (bounds.height - h) / 2, width: max(0, bounds.width - 33), height: h)
        } else {
            label.frame = NSRect(x: 8, y: (bounds.height - h) / 2, width: max(0, bounds.width - 16), height: h)
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = group.color.nsColor
            if vertical {
                layer?.backgroundColor = color.withAlphaComponent(group.collapsed ? 0.14 : 0.22).cgColor
                layer?.borderWidth = 0
                label.textColor = .labelColor
                chevron.contentTintColor = color
            } else {
                layer?.backgroundColor = (group.collapsed ? color.withAlphaComponent(0.22) : color).cgColor
                label.textColor = group.collapsed ? .labelColor : .white
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let strip, let tabs = strip.tabs else { return }
        strip.browser.toggleCollapsed(group.id, in: tabs, window: strip.windowState)
        strip.keepPageFocus()
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        strip?.menu(forGroup: group.id, from: self)
    }
}

/// A menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, key: String = "", modifiers: NSEvent.ModifierFlags = .command, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// The group editor: name and color (a dropdown of the fixed palette). Changes apply as you make
/// them; Return or a click outside closes it.
struct GroupEditor: View {
    @State var name: String
    @State var color: GroupColor
    let apply: (String, GroupColor) -> Void
    let done: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name this group", text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(done)
            Picker("Color", selection: $color) {
                ForEach(GroupColor.allCases) { c in
                    Label { Text(c.title) } icon: { Image(nsImage: StripContentView.swatch(c.nsColor)) }
                        .tag(c)
                }
            }
            .pickerStyle(.menu)
        }
        .padding(12)
        .frame(width: 240)
        .onAppear { focused = true }
        .onChange(of: name) { _, new in apply(new, color) }
        .onChange(of: color) { _, new in apply(name, new) }
    }
}

/// The strip in SwiftUI.
struct TabStripBar: NSViewRepresentable {
    let browser: BrowserState
    let window: WindowState
    @ObservedObject var tabs: SpaceTabs
    let name: String
    let color: NSColor

    func makeNSView(context: Context) -> TabStripView {
        TabStripView(browser: browser, window: window)
    }

    func updateNSView(_ view: TabStripView, context: Context) {
        view.tabs = tabs
        view.setSpace(name: name, color: color)
    }
}

// MARK: - Vertical tabs

/// The sidebar beside the rail when a window shows its tabs vertically: the space's name and a
/// "+" button on top, then its pinned tabs as icons, group headers that collapse, and one row per
/// tab. The same drag and drop and context menus as the strip.
final class VerticalTabsView: NSView {
    let browser: BrowserState
    let windowState: WindowState
    private let dot = NSView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    let content: StripContentView
    private let plusButton = NSButton()
    private let separator = NSView()
    static let header: CGFloat = 40

    init(browser: BrowserState, window: WindowState) {
        self.browser = browser
        windowState = window
        content = StripContentView(browser: browser, window: window, axis: .vertical)
        super.init(frame: .zero)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 3
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.drawsBackground = false
        scrollView.documentView = content
        StripContentView.configurePlusButton(plusButton)
        plusButton.target = self
        plusButton.action = #selector(newTab)
        separator.wantsLayer = true
        for view in [dot, nameLabel, scrollView, plusButton, separator] { addSubview(view) }
        content.onChange = { [weak self] in self?.needsLayout = true }
        registerForDraggedTypes([.ismithTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var tabs: SpaceTabs? {
        get { content.tabs }
        set { if newValue !== content.tabs { content.tabs = newValue } }
    }

    func setSpace(name: String, color: NSColor) {
        if nameLabel.stringValue != name {
            nameLabel.stringValue = name
            needsLayout = true
        }
        dot.layer?.backgroundColor = color.cgColor
        separator.layer?.backgroundColor = color.withAlphaComponent(0.3).cgColor
    }

    override func layout() {
        super.layout()
        let w = bounds.width
        let h = Self.header
        dot.frame = NSRect(x: 14, y: (h - 10) / 2, width: 10, height: 10)
        let nameHeight = nameLabel.intrinsicContentSize.height
        nameLabel.frame = NSRect(x: 31, y: (h - nameHeight) / 2, width: max(0, w - 31 - 40), height: nameHeight)
        plusButton.frame = NSRect(x: w - 36, y: (h - 28) / 2, width: 28, height: 28)
        separator.frame = NSRect(x: w - 1, y: 0, width: 1, height: bounds.height)
        scrollView.frame = NSRect(x: 0, y: h, width: w - 1, height: max(0, bounds.height - h))
        let width = scrollView.contentSize.width
        let needed = content.layoutRows(width: width)
        content.frame = NSRect(x: 0, y: 0, width: width, height: max(needed, scrollView.contentSize.height))
        content.scrollSelectedIntoView()
    }

    @objc private func newTab() {
        browser.newTab(in: windowState)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { content.draggingUpdated(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { content.draggingUpdated(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { content.draggingExited(sender) }
    override func concludeDragOperation(_ sender: NSDraggingInfo?) { content.concludeDragOperation(sender) }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { content.performDragOperation(sender) }

    // As in the strip: empty space moves the window; a double-click opens a tab.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { browser.newTab(in: windowState) } else { window?.performDrag(with: event) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
}

/// The sidebar in SwiftUI.
struct VerticalTabsBar: NSViewRepresentable {
    let browser: BrowserState
    let window: WindowState
    @ObservedObject var tabs: SpaceTabs
    let name: String
    let color: NSColor

    func makeNSView(context: Context) -> VerticalTabsView {
        VerticalTabsView(browser: browser, window: window)
    }

    func updateNSView(_ view: VerticalTabsView, context: Context) {
        view.tabs = tabs
        view.setSpace(name: name, color: color)
    }
}
