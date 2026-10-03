import AppKit
import Combine
import SwiftUI

/// The tab strip across the top of a window, for the space it shows: the space's name, its tabs
/// and group labels, and a "+" button. AppKit rather than SwiftUI, for drag and drop: tabs drag
/// within the strip, into and out of groups, onto a space in the rail, into another window's strip,
/// or out of the window into a new one.
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
        content = StripContentView(browser: browser, window: window)
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
        plusButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "New tab")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .medium))
        plusButton.isBordered = false
        plusButton.imagePosition = .imageOnly
        plusButton.contentTintColor = .secondaryLabelColor
        plusButton.toolTip = "New tab  ⌘T"
        plusButton.target = self
        plusButton.action = #selector(newTab)
        for view in [dot, nameLabel, scrollView, plusButton] { addSubview(view) }
        content.onChange = { [weak self] in self?.needsLayout = true }
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

/// The tabs and group labels, laid out left to right. Also the drop target for tabs.
final class StripContentView: NSView {
    let browser: BrowserState
    let windowState: WindowState
    var onChange: (() -> Void)?
    private var tabViews: [UUID: TabItemView] = [:]
    private var chipViews: [UUID: GroupChipView] = [:]
    /// What's shown, left to right.
    private(set) var ordered: [NSView] = []
    private let indicator = NSView()
    private var subscription: AnyCancellable?
    private var reloadScheduled = false
    /// A group just created from a menu: its editor opens once its label is on screen.
    var pendingEdit: UUID?
    private var popover: NSPopover?

    static let gap: CGFloat = 4
    static let maxTab: CGFloat = 200
    static let minTab: CGFloat = 110

    init(browser: BrowserState, window: WindowState) {
        self.browser = browser
        windowState = window
        super.init(frame: .zero)
        indicator.wantsLayer = true
        indicator.layer?.cornerRadius = 1
        indicator.isHidden = true
        addSubview(indicator)
        registerForDraggedTypes([.ismithTab])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    var tabs: SpaceTabs? {
        didSet {
            subscription = tabs?.objectWillChange.sink { [weak self] _ in self?.scheduleReload() }
            reload()
        }
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
        var views: [NSView] = []
        var usedTabs = Set<UUID>()
        var usedChips = Set<UUID>()
        for item in layout.items {
            switch item {
            case let .group(group, count):
                let view = chipViews[group.id] ?? GroupChipView(strip: self)
                chipViews[group.id] = view
                view.configure(group: group, count: count)
                usedChips.insert(group.id)
                views.append(view)
            case let .tab(id, group):
                guard let tab = tabs.tab(id) else { continue }
                let view = tabViews[id].flatMap { $0.tab === tab ? $0 : nil } ?? TabItemView(tab: tab, strip: self)
                tabViews[id] = view
                view.configure(group: group, selected: layout.selected == id, marked: tabs.marked.contains(id))
                usedTabs.insert(id)
                views.append(view)
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

    /// Sizes and places every item; returns the width they need. Tabs share the space between
    /// `minTab` and `maxTab` wide; past that the strip scrolls.
    func layoutItems(maxWidth: CGFloat, height: CGFloat) -> CGFloat {
        let chips = ordered.compactMap { $0 as? GroupChipView }
        let chipWidth = chips.reduce(0) { $0 + $1.preferredWidth + Self.gap }
        let tabCount = ordered.count - chips.count
        let gaps = Self.gap * CGFloat(max(0, ordered.count - 1))
        let tabWidth = tabCount == 0 ? 0
            : min(Self.maxTab, max(Self.minTab, floor((maxWidth - chipWidth - gaps) / CGFloat(tabCount))))
        var x: CGFloat = 0
        for view in ordered {
            if let chip = view as? GroupChipView {
                if x > 0 { x += Self.gap }
                chip.frame = NSRect(x: x, y: (height - 22) / 2, width: chip.preferredWidth, height: 22)
                x += chip.preferredWidth + Self.gap
            } else {
                view.frame = NSRect(x: x, y: (height - 30) / 2, width: tabWidth, height: 30)
                x += tabWidth + Self.gap
            }
        }
        return max(0, x - Self.gap)
    }

    /// VoiceOver reads the strip left to right, whatever order the views were added in.
    override func accessibilityChildren() -> [Any]? { ordered }

    func scrollSelectedIntoView() {
        guard let id = tabs?.layout.selected, let view = tabViews[id] else { return }
        scrollToVisible(view.frame.insetBy(dx: -8, dy: 0))
    }

    // MARK: - Dropping tabs

    /// Where a tab dropped at `point` goes: before which tab (nil: the end), in which group, and
    /// where to draw the insertion line.
    func dropTarget(at point: NSPoint) -> (before: UUID?, group: UUID?, x: CGFloat) {
        guard let layout = tabs?.layout else { return (nil, nil, 0) }
        let ids = layout.ids
        func after(_ id: UUID) -> UUID? {
            guard let i = ids.firstIndex(of: id), i + 1 < ids.count else { return nil }
            return ids[i + 1]
        }
        for view in ordered where point.x < view.frame.maxX + Self.gap / 2 {
            let f = view.frame
            if let tabView = view as? TabItemView {
                let group = layout.groupID(of: tabView.tab.id)
                return point.x < f.midX ? (tabView.tab.id, group, f.minX - 2) : (after(tabView.tab.id), group, f.maxX + 2)
            }
            if let chip = view as? GroupChipView {
                let members = layout.tabs(in: chip.group.id)
                if chip.group.collapsed {
                    // A collapsed group is one item: drop before or after it.
                    return point.x < f.midX ? (members.first, nil, f.minX - 2)
                        : (members.last.flatMap(after), nil, f.maxX + 2)
                }
                // The label's left edge drops before the group; the rest drops into it, first.
                return point.x < f.minX + f.width * 0.3 ? (members.first, nil, f.minX - 2) : (members.first, chip.group.id, f.maxX + 2)
            }
        }
        return (nil, nil, (ordered.last?.frame.maxX ?? 0) + 2)
    }

    private func showIndicator(_ target: (before: UUID?, group: UUID?, x: CGFloat)) {
        let color = target.group.flatMap { tabs?.layout.group($0)?.color.nsColor } ?? .controlAccentColor
        indicator.layer?.backgroundColor = color.cgColor
        indicator.frame = NSRect(x: max(0, target.x - 1), y: 6, width: 2, height: bounds.height - 12)
        indicator.isHidden = false
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard case .tab = browser.drag, tabs != nil else {
            indicator.isHidden = true
            return []
        }
        showIndicator(dropTarget(at: convert(sender.draggingLocation, from: nil)))
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        indicator.isHidden = true
    }

    override func concludeDragOperation(_ sender: NSDraggingInfo?) {
        indicator.isHidden = true
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        indicator.isHidden = true
        guard case let .tab(id, windowID, spaceID) = browser.drag, let tabs,
              let source = browser.windows.first(where: { $0.id == windowID }) else { return false }
        let target = dropTarget(at: convert(sender.draggingLocation, from: nil))
        browser.moveTab(id, from: (source, spaceID), to: (windowState, tabs.spaceID), before: target.before, group: target.group)
        return true
    }

    override func mouseDown(with event: NSEvent) {
        superview?.superview?.superview?.mouseDown(with: event) // the strip: window drag or new tab
    }

    // MARK: - Menus

    func menu(forTab id: UUID) -> NSMenu? {
        guard let tabs, let tab = tabs.tab(id) else { return nil }
        let browser = browser
        let window = windowState
        let targets = tabs.targets(for: id)
        let many = targets.count > 1
        let noun = many ? "\(targets.count) Tabs" : "Tab"
        let layout = tabs.layout
        let menu = NSMenu()
        menu.addItem(ActionItem("New Tab to the Right") { browser.newTab(after: id, in: tabs, window: window) })
        menu.addItem(.separator())
        menu.addItem(ActionItem("Reload") { browser.reload(tab, in: tabs) })
        menu.addItem(ActionItem("Duplicate") { browser.duplicate(id, in: tabs, window: window) })
        let keepAlive = ActionItem(tab.keepAliveSetting == nil && tab.keepAlive ? "Keep Alive (automatic for this site)" : "Keep Alive") {
            browser.setKeepAlive(!tab.keepAlive, for: tab, in: tabs)
        }
        keepAlive.state = tab.keepAlive ? .on : .off
        keepAlive.toolTip = "Never unloaded or throttled in the background, so mail counts update and calls ring."
        menu.addItem(keepAlive)
        menu.addItem(.separator())
        menu.addItem(ActionItem("Add \(noun) to New Group") { [weak self] in
            if let group = browser.createGroup(with: targets, in: tabs) { self?.pendingEdit = group }
        })
        let others = layout.groups.filter { g in !targets.allSatisfy { layout.groupID(of: $0) == g.id } }
        if !others.isEmpty {
            let sub = NSMenu()
            for group in others {
                let item = ActionItem(group.name.isEmpty ? "Unnamed group" : group.name) {
                    tabs.update { $0.add(targets, to: group.id) }
                    tabs.marked = []
                }
                item.image = Self.swatch(group.color.nsColor)
                sub.addItem(item)
            }
            let item = NSMenuItem(title: "Add \(noun) to Group", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        if targets.contains(where: { layout.groupID(of: $0) != nil }) {
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
                item.image = Self.swatch(Palette.nsColor(space.def.color))
                sub.addItem(item)
            }
            let item = NSMenuItem(title: "Move \(noun) to Space", action: nil, keyEquivalent: "")
            item.submenu = sub
            menu.addItem(item)
        }
        if !many {
            menu.addItem(ActionItem("Move Tab to New Window") { browser.moveToNewWindow(id, from: tabs, in: window) })
        }
        menu.addItem(.separator())
        menu.addItem(ActionItem("Close \(noun)") { browser.closeTabs(targets, in: tabs) })
        if layout.count > targets.count {
            menu.addItem(ActionItem("Close Other Tabs") {
                browser.closeTabs(layout.ids.filter { !targets.contains($0) }, in: tabs)
            })
        }
        return menu
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

    /// The group's name and color, in a popover under its label.
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
        popover.show(relativeTo: chip.bounds, of: chip, preferredEdge: .maxY)
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

/// One tab in the strip: loading spinner or Keep alive mark, title, close button. The group's
/// color runs along its bottom edge.
final class TabItemView: NSView, NSDraggingSource {
    let tab: Tab
    private weak var strip: StripContentView?
    private(set) var group: TabGroup?
    private var isSelected = false
    private var isMarked = false
    private var hovering = false
    private let titleField = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let keepAliveIcon = NSImageView()
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
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        keepAliveIcon.image = NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Keep alive")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        keepAliveIcon.contentTintColor = .secondaryLabelColor
        keepAliveIcon.toolTip = "Kept alive in the background"
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tab")?
            .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
        closeButton.isBordered = false
        closeButton.imagePosition = .imageOnly
        closeButton.contentTintColor = .secondaryLabelColor
        closeButton.toolTip = "Close tab  ⌘W"
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        for view in [spinner, keepAliveIcon, titleField, closeButton] { addSubview(view) }
        tab.$title.sink { [weak self] title in
            self?.titleField.stringValue = title
            self?.toolTip = title
        }.store(in: &subscriptions)
        tab.$isLoading.sink { [weak self] loading in
            if loading { self?.spinner.startAnimation(nil) } else { self?.spinner.stopAnimation(nil) }
            self?.needsLayout = true
        }.store(in: &subscriptions)
        tab.$keepAliveSetting.combineLatest(tab.$url).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.needsLayout = true }
        }.store(in: &subscriptions)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(group: TabGroup?, selected: Bool, marked: Bool) {
        self.group = group
        isSelected = selected
        isMarked = marked
        needsDisplay = true
        needsLayout = true
        setAccessibilityElement(true)
        setAccessibilityRole(.radioButton)
        setAccessibilityValue(selected)
    }

    override func accessibilityLabel() -> String? {
        tab.title + (tab.keepAlive ? ", kept alive" : "") + (group.map { ", in group \($0.name)" } ?? "")
    }

    override func accessibilityChildren() -> [Any]? { [closeButton] }

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
        var x: CGFloat = 10
        let showMark = tab.isLoading || tab.keepAlive
        spinner.frame = NSRect(x: x, y: (h - 14) / 2, width: 14, height: 14)
        keepAliveIcon.frame = spinner.frame
        keepAliveIcon.isHidden = tab.isLoading || !tab.keepAlive
        if showMark { x += 19 }
        let showClose = isSelected || hovering
        closeButton.isHidden = !showClose
        closeButton.frame = NSRect(x: bounds.width - 24, y: (h - 16) / 2, width: 16, height: 16)
        let titleHeight = titleField.intrinsicContentSize.height
        titleField.frame = NSRect(x: x, y: (h - titleHeight) / 2, width: max(0, bounds.width - x - 28), height: titleHeight)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        groupLine.frame = NSRect(x: 8, y: 0, width: max(0, bounds.width - 16), height: 2.5)
        CATransaction.commit()
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
            } else {
                background = .clear
            }
            layer?.backgroundColor = background.cgColor
            layer?.borderWidth = isSelected ? 1 : 0
            layer?.borderColor = NSColor.separatorColor.cgColor
            layer?.shadowOpacity = isSelected ? 0.08 : 0
            layer?.shadowRadius = 2
            layer?.shadowOffset = NSSize(width: 0, height: -1)
            groupLine.backgroundColor = group?.color.nsColor.cgColor
            groupLine.isHidden = group == nil
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
        if flags.contains(.command) {
            // ⌘-click marks tabs for a group or a bulk close.
            if tab.id != tabs.layout.selected {
                if tabs.marked.contains(tab.id) { tabs.marked.remove(tab.id) } else { tabs.marked.insert(tab.id) }
            }
        } else if flags.contains(.shift), let selected = tabs.layout.selected,
                  let a = tabs.layout.index(of: selected), let b = tabs.layout.index(of: tab.id) {
            tabs.marked = Set(tabs.layout.ids[min(a, b)...max(a, b)])
        } else {
            if !tabs.marked.contains(tab.id) { tabs.marked = [] }
            strip.browser.selectTab(tab.id, in: tabs)
        }
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

/// A group's label: its name on its color, and the tab count when collapsed. Click to collapse
/// or expand; right-click to rename, recolor, ungroup or close.
final class GroupChipView: NSView {
    private weak var strip: StripContentView?
    private(set) var group = TabGroup(name: "", color: .grey)
    private var count = 0
    private let label = NSTextField(labelWithString: "")

    init(strip: StripContentView) {
        self.strip = strip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 6
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(group: TabGroup, count: Int) {
        self.group = group
        self.count = count
        let text = NSMutableAttributedString(string: group.name, attributes: [.font: NSFont.systemFont(ofSize: 11.5, weight: .semibold)])
        if group.collapsed {
            text.append(NSAttributedString(string: (group.name.isEmpty ? "" : "  ") + "\(count)",
                                           attributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)]))
        }
        label.attributedStringValue = text
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
        label.frame = NSRect(x: 8, y: (bounds.height - h) / 2, width: max(0, bounds.width - 16), height: h)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color = group.color.nsColor
            layer?.backgroundColor = (group.collapsed ? color.withAlphaComponent(0.22) : color).cgColor
            label.textColor = group.collapsed ? .labelColor : .white
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let strip, let tabs = strip.tabs else { return }
        strip.browser.toggleCollapsed(group.id, in: tabs, window: strip.windowState)
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
