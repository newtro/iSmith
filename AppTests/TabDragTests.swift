import AppKit
import XCTest
@testable import iSmith

/// Dragging a tab: it must reorder the tab, not move the window. The strip sits in the title bar
/// of a window with a full-size content view, where AppKit turns a drag into a window move unless
/// the view under the mouse blocks it (only controls do). These run a real browser window.
@MainActor
final class TabDragTests: XCTestCase {
    private var wired: WiredBrowser!
    private var controller: BrowserWindowController!

    override func setUp() async throws {
        wired = try WiredBrowser()
        // The window opens on the space's (empty) home tab; the tests want only their own.
        wired.browser.closeTabs(wired.tabs.layout.ids, in: wired.tabs)
        for name in ["A", "B", "C", "D"] {
            wired.browser.openTab(in: wired.window, space: wired.spaceID, url: nil, title: name)
        }
        controller = BrowserWindowController(state: wired.window, browser: wired.browser, cascadeFrom: nil, closed: { _ in })
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: 80, y: 80, width: 1200, height: 700), display: true)
        window.orderBack(nil)
        try await settle()
    }

    override func tearDown() async throws {
        controller?.window?.orderOut(nil)
        controller = nil
        await wired?.tearDown()
        wired = nil
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 400_000_000)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 100_000_000)
    }

    private func views<T: NSView>(_ type: T.Type) -> [T] {
        func find(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(find) }
        return controller.window?.contentView?.superview.map(find) ?? []
    }

    private var strip: StripContentView { views(StripContentView.self)[0] }

    /// The part of `view` AppKit keeps from moving the window when it's in the title bar. Read
    /// through AppKit's own (private) answer when it exists, so the test checks real behavior;
    /// otherwise a control, the only kind of view that blocks it.
    private func blocksWindowMove(_ view: NSView) -> NSRect {
        let selector = NSSelectorFromString("_opaqueRectForWindowMoveWhenInTitlebar")
        guard view.responds(to: selector) else { return view is NSControl ? view.bounds : .zero }
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSRect
        return unsafeBitCast(view.method(for: selector), to: Getter.self)(view, selector)
    }

    func testTabsAndGroupLabelsSitInTheTitleBarAndKeepDragsFromMovingTheWindow() async throws {
        let tabs = wired.tabs
        wired.browser.createGroup(with: [tabs.layout.ids[1], tabs.layout.ids[2]], in: tabs)
        try await settle()
        let window = try XCTUnwrap(controller.window)
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(titleBarHeight, 20, "the window has a title bar the strip overlaps")
        let items: [NSView] = views(TabItemView.self) + views(GroupChipView.self)
        XCTAssertEqual(items.count, 5, "four tabs and a group label")
        for item in items {
            let frame = item.convert(item.bounds, to: nil)
            XCTAssertGreaterThan(frame.maxY, window.frame.height - titleBarHeight, "\(type(of: item)) reaches into the title bar")
            XCTAssertEqual(blocksWindowMove(item), item.bounds, "a drag on a \(type(of: item)) never moves the window")
            // The mouse goes to the tab (its title label passes clicks on to it).
            let hit = try XCTUnwrap(window.contentView?.superview?.hitTest(NSPoint(x: frame.midX, y: frame.midY)))
            XCTAssertTrue(hit === item || hit.isDescendant(of: item), "a click lands on the \(type(of: item)), not \(type(of: hit))")
        }
        // Empty strip space still moves the window.
        let empty = try XCTUnwrap(views(TabStripView.self).first)
        XCTAssertEqual(blocksWindowMove(empty), .zero, "empty strip space drags the window")
    }

    func testDraggingATabShowsTheInsertionMarkerAndDropsItThere() throws {
        let tabs = wired.tabs
        let ids = tabs.layout.ids
        let strip = strip
        let tabViews = views(TabItemView.self).sorted { $0.frame.minX < $1.frame.minX }
        XCTAssertEqual(tabViews.map(\.tab.id), ids)
        // Drag A to the right half of C: it goes between C and D.
        wired.browser.drag = .tab(ids[0], window: wired.window.id, space: wired.spaceID)
        let c = tabViews[2].frame
        let point = strip.convert(NSPoint(x: c.maxX - 10, y: c.midY), to: nil)
        let info = FakeDrag(location: point, window: try XCTUnwrap(controller.window))
        XCTAssertEqual(strip.draggingEntered(info), .move)
        let marker = try XCTUnwrap(strip.indicatorFrame, "the insertion marker shows")
        XCTAssertEqual(marker.midX, c.maxX + 2, accuracy: 2, "between C and D")
        XCTAssertEqual(tabViews[0].alphaValue, 0.45, accuracy: 0.01, "the dragged tab is dimmed")
        XCTAssertTrue(strip.performDragOperation(info))
        XCTAssertNil(strip.indicatorFrame)
        XCTAssertEqual(tabViews[0].alphaValue, 1)
        XCTAssertEqual(tabs.layout.ids, [ids[1], ids[2], ids[0], ids[3]])
        wired.browser.drag = nil
    }
}

/// Just enough of a drag for the strip's drop handling.
final class FakeDrag: NSObject, NSDraggingInfo {
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?

    init(location: NSPoint, window: NSWindow) {
        draggingLocation = location
        draggingDestinationWindow = window
    }

    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: NSPasteboard { NSPasteboard(name: .init("iSmithTests.drag")) }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
                                using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
