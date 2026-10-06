import AppKit
import XCTest
@testable import iSmith

/// A visual smoke run of tab management in a real browser window on screen, with screenshots of
/// that window only (`screencapture -l`). Skipped unless `ISMITH_SMOKE_SHOTS=<folder>` is set
/// (`TEST_RUNNER_ISMITH_SMOKE_SHOTS=<folder> xcodebuild test -only-testing:iSmithTests/TabSmokeShots`).
/// Pages come from local servers, one per "site", each with its own icon.
@MainActor
final class TabSmokeShots: XCTestCase {
    func testTabManagementShots() async throws {
        guard let folder = ProcessInfo.processInfo.environment["ISMITH_SMOKE_SHOTS"], !folder.isEmpty else {
            throw XCTSkip("set ISMITH_SMOKE_SHOTS to a folder to take the smoke screenshots")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

        let sites: [(String, NSColor)] = [("(3) Contoso Mail", .systemBlue), ("Contoso Boards", .systemGreen),
                                          ("Contoso Repos", .systemPurple), ("Contoso Wiki", .systemOrange),
                                          ("Contoso Calendar", .systemRed), ("Contoso Docs", .systemTeal),
                                          ("Contoso Pipelines", .systemYellow)]
        var servers: [TestHTTPServer] = []
        for (title, color) in sites {
            let letter = String(title.replacingOccurrences(of: "(3) ", with: "").dropFirst("Contoso ".count).prefix(1))
            let server = try TestHTTPServer(routes: [
                "/": .html("<html><head><title>\(title)</title><link rel=icon href=/icon.png></head><body style='font:28px -apple-system;padding:40px'><h1>\(title)</h1><p>A fixture page.</p></body></html>"),
                "/icon.png": .init(type: "image/png", body: Self.icon(letter, color)),
            ])
            try await server.start()
            servers.append(server)
        }
        defer { servers.forEach { $0.stop() } }

        let wired = try WiredBrowser(extraSpaces: ["fabrikam"])
        let browser = wired.browser
        let window = wired.window
        let tabs = wired.tabs
        browser.closeTabs(tabs.layout.ids, in: tabs)
        let opened = servers.map { browser.openTab(in: window, space: wired.spaceID, url: $0.url("/")) }
        let controller = BrowserWindowController(state: window, browser: browser, cascadeFrom: nil, closed: { _ in })
        let nsWindow = try XCTUnwrap(controller.window)
        nsWindow.setFrame(NSRect(x: 120, y: 120, width: 1280, height: 760), display: true)
        nsWindow.makeKeyAndOrderFront(nil)
        // Every page loads once (for its title and icon), then the first one shows.
        for tab in opened {
            browser.selectTab(tab.id, in: tabs)
            _ = await eventually(timeout: 15) { tab.webView?.isLoading == false && tab.webView?.url != nil }
        }
        _ = await eventually(timeout: 10) { opened.allSatisfy { Favicons.shared.icon(for: $0.url) != nil } }
        let ids = opened.map(\.id)
        browser.pin([ids[0], ids[4]], in: tabs)
        browser.createGroup(with: [ids[1], ids[2]], in: tabs)
        tabs.update {
            if let g = $0.group(of: ids[1])?.id { $0.rename(g, to: "Sprint") }
        }
        browser.selectTab(ids[3], in: tabs)

        func settle() async {
            try? await Task.sleep(nanoseconds: 700_000_000)
            nsWindow.contentView?.layoutSubtreeIfNeeded()
            nsWindow.displayIfNeeded()
        }
        // The test host may not record the screen, so a watcher outside takes each shot: this
        // writes "<name> <window number>" to stage.txt and waits for <name>.png.
        func shot(_ name: String, window: NSWindow? = nil) async throws {
            await settle()
            let target = window ?? nsWindow
            let png = out.appendingPathComponent(name + ".png")
            try Data("\(name) \(target.windowNumber)\n".utf8).write(to: out.appendingPathComponent("stage.txt"), options: .atomic)
            let taken = await eventually(timeout: 30) { FileManager.default.fileExists(atPath: png.path) }
            XCTAssertTrue(taken, "screenshot \(name)")
        }
        func views<T: NSView>(_ type: T.Type) -> [T] {
            func find(_ view: NSView) -> [T] { ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap(find) }
            return nsWindow.contentView?.superview.map(find) ?? []
        }

        // 1. The strip: two pinned tabs (icons, Mail's unread count), a group, tabs with icons.
        try await shot("1-strip-pinned")

        // 2. Picking several tabs with ⌘-click and ⇧-click.
        _ = tabs.click(ids[5], .command)
        _ = tabs.click(ids[6], .command)
        try await shot("2-strip-picked")
        tabs.marked = []

        // 3. Dragging Docs (ids[5]) to the left of Repos: the insertion marker, then the drop.
        let strip = try XCTUnwrap(views(StripContentView.self).first)
        let repos = try XCTUnwrap(strip.view(for: ids[2]))
        browser.drag = .tab(ids[5], window: window.id, space: wired.spaceID)
        let point = strip.convert(NSPoint(x: repos.frame.minX + 12, y: repos.frame.midY), to: nil)
        let drag = FakeDrag(location: point, window: nsWindow)
        XCTAssertEqual(strip.draggingUpdated(drag), .move)
        try await shot("3-drag-marker")
        XCTAssertTrue(strip.performDragOperation(drag))
        browser.drag = nil
        XCTAssertEqual(tabs.layout.groupID(of: ids[5]), tabs.layout.groupID(of: ids[2]), "dropped into the group, before Repos")
        try await shot("4-drag-dropped")

        // 4. The tab overview (⌘⇧A), filtered.
        window.overviewShown = true
        await settle()
        let sheet = try XCTUnwrap(nsWindow.attachedSheet, "the overview is a sheet")
        try await shot("5-overview", window: sheet)
        if let field = sheet.firstResponder as? NSTextView {
            field.insertText("re", replacementRange: field.selectedRange())
        }
        try await shot("6-overview-filtered", window: sheet)
        window.overviewShown = false
        await settle()

        // 5. Vertical tabs: the sidebar beside the rail, pinned icons on top, the group as a section.
        window.verticalTabs = true
        try await shot("7-vertical")
        XCTAssertNotNil(tabs.selected?.webView?.window, "the page stays on screen when the layout changes")
        if let g = tabs.layout.group(of: ids[1])?.id { browser.toggleCollapsed(g, in: tabs, window: window) }
        try await shot("8-vertical-collapsed")
        window.verticalTabs = false
        await settle()
        XCTAssertNotNil(tabs.selected?.webView?.window, "and when it changes back")

        nsWindow.orderOut(nil)
        await wired.tearDown()
    }

    /// A 32-pixel PNG: a letter on a colored tile.
    private static func icon(_ letter: String, _ color: NSColor) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 32, height: 32), xRadius: 8, yRadius: 8).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 20), .foregroundColor: NSColor.white]
        let size = letter.size(withAttributes: attributes)
        letter.draw(at: NSPoint(x: 16 - size.width / 2, y: 16 - size.height / 2), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])!
    }
}
