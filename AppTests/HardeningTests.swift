import BrowserData
import Combine
import WebKit
import XCTest
@testable import iSmith

/// P8: the loaded-tab cap and memory pressure, overlapping web view builds, and ⌘⇧T's fallback
/// to a closed window.
@MainActor
final class HardeningTests: XCTestCase {
    private var server: TestHTTPServer!
    private var wired: WiredBrowser!

    override func setUp() async throws {
        server = try TestHTTPServer(routes: ["/page.html": .html("<title>Page</title><p>page</p>")])
        try await server.start()
        wired = try WiredBrowser(extraSpaces: ["other"])
    }

    override func tearDown() async throws {
        await wired?.tearDown()
        server?.stop()
    }

    private func url(_ n: Int) -> URL { URL(string: "http://127.0.0.1:\(server.port)/page.html?\(n)")! }

    /// Past `maxLoadedBackgroundTabs`, the least recently shown background tabs are unloaded once
    /// they've been in the background for a minute; younger ones, Keep alive tabs and sites
    /// allowed to notify stay. A memory-pressure warning unloads tabs idle for `pressureIdle`
    /// (and the minute timer keeps doing so while it lasts); critical pressure unloads every
    /// background tab.
    func testLoadedBackgroundTabsAreCapped() async throws {
        let browser = wired.browser
        let count = BrowserState.maxLoadedBackgroundTabs + 3
        var tabs: [Tab] = []
        for n in 0..<count {
            // One tab is on another site, which may show notifications.
            let address = n == 1 ? URL(string: "http://localhost:\(server.port)/page.html?\(n)")! : url(n)
            tabs.append(browser.openTab(in: wired.window, space: wired.spaceID, url: address, select: false))
        }
        try browser.data?.sites.setDecision(.allow, for: .notifications, origin: WebNotifications.originKey(tabs[1].url!)!)
        let kept = browser.openTab(in: wired.window, space: wired.spaceID, url: url(99), keepAlive: true, select: false)
        let built = await eventually(timeout: 30) { tabs.allSatisfy { $0.webView != nil } && kept.webView != nil }
        XCTAssertTrue(built)
        let visible = try XCTUnwrap(wired.tabs.selected)
        let background = tabs.filter { $0 !== visible }
        XCTAssertEqual(background.count, count, "the window's first (empty) tab is the one on screen")
        let now = Date()
        // Oldest first: background[0] was shown longest ago. The three oldest are past the grace
        // period; everything else is recent. background[1] may notify.
        for (i, tab) in background.enumerated() { tab.lastShown = now.addingTimeInterval(-Double(background.count - i)) }
        background[0].lastShown = now.addingTimeInterval(-BrowserState.loadedTabGrace - 30)
        background[1].lastShown = now.addingTimeInterval(-BrowserState.loadedTabGrace - 20)
        background[2].lastShown = now.addingTimeInterval(-BrowserState.loadedTabGrace - 10)
        kept.lastShown = now.addingTimeInterval(-BrowserState.loadedTabGrace - 40)

        browser.hibernateIdleTabs(now: now)
        let trimmed = await eventually { background[0].webView == nil && background[2].webView == nil }
        XCTAssertTrue(trimmed, "the two oldest beyond the cap were unloaded")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(background[1].webView, "a site allowed to notify keeps its half hour")
        let loaded = background.filter { $0.webView != nil }.count
        XCTAssertEqual(loaded, background.count - 2, "the others stay: within the cap or too recent")
        XCTAssertNotNil(visible.webView, "the tab on screen stays")
        XCTAssertNotNil(kept.webView, "Keep alive stays")
        XCTAssertNotNil(background[0].savedState ?? background[0].url, "an unloaded tab keeps where it was")

        // A memory-pressure warning: tabs idle for `pressureIdle` go, recent ones stay.
        background[3].lastShown = now.addingTimeInterval(-BrowserState.pressureIdle - 10)
        browser.memoryPressureChanged(.warning, now: now)
        XCTAssertEqual(browser.hibernationIdleLimit, BrowserState.pressureIdle, "the minute timer follows the warning")
        let warned = await eventually { background[3].webView == nil }
        XCTAssertTrue(warned, "a tab idle past the pressure limit was unloaded")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNotNil(background[4].webView, "a recent tab stays under a warning")

        // Critical: every background tab that can be unloaded is.
        browser.memoryPressureChanged(.critical, now: now)
        XCTAssertEqual(browser.hibernationIdleLimit, 0)
        let all = await eventually { background.allSatisfy { $0.webView == nil } }
        XCTAssertTrue(all, "critical pressure unloaded every background tab")
        XCTAssertNotNil(visible.webView)
        XCTAssertNotNil(kept.webView)
        browser.memoryPressureChanged(.normal, now: now)
        XCTAssertEqual(browser.hibernationIdleLimit, BrowserState.hibernateAfter, "back to normal")
    }

    /// Two builds for one tab overlapping (a tab moved again while its store opened): only the
    /// newer makes a web view, and the tab counts as building until it has.
    func testOverlappingBuildsMakeOneWebView() async throws {
        let browser = wired.browser
        // A new space: its store isn't open yet, so both builds wait for it.
        browser.createSpace(name: "Third", color: 2, home: "", choices: [:], newNames: [:], in: wired.window)
        let spaceID = try XCTUnwrap(wired.window.activeSpaceID)
        let tab = try XCTUnwrap(wired.window.spaces[spaceID]?.selected)
        XCTAssertTrue(tab.isBuilding, "the space's first tab is on its way")
        var attached: [WKWebView] = []
        let watch = tab.$webView.dropFirst().sink { if let webView = $0 { attached.append(webView) } }
        defer { watch.cancel() }
        await browser.buildWebView(for: tab, space: spaceID, state: nil, load: URLRequest(url: url(2)))
        let settled = await eventually { !tab.isBuilding }
        XCTAssertTrue(settled)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(attached.count, 1, "one web view, not two")
        XCTAssertTrue(tab.webView === attached.first)
        try await wired.waitForLoad(tab, path: "/page.html")
        XCTAssertEqual(tab.webView?.url?.query, "2", "the build asked for last wins")
    }

    /// ⌘⇧T in a space with no closed tab brings back a closed window only if that window closed
    /// after the last tab closed anywhere.
    func testReopenFallsBackToAWindowOnlyIfItClosedLast() async throws {
        let browser = wired.browser
        let main = wired.window
        // A second window with a tab in "other", then closed.
        let second = browser.newWindow(space: "other")
        XCTAssertEqual(second.allTabs.count, 1)
        browser.windowWillClose(second)
        XCTAssertTrue(browser.canReopenClosedWindow)
        // Then a tab closed in the fixture space.
        let tab = browser.openTab(in: main, space: wired.spaceID, url: url(1))
        browser.closeTab(tab.id, in: wired.tabs)
        // In "other" (nothing closed there), ⌘⇧T doesn't bring back the older window.
        browser.select(try XCTUnwrap(browser.space("other")), in: main)
        let windows = browser.windows.count
        browser.reopenClosedTab(in: main)
        XCTAssertEqual(browser.windows.count, windows, "no window came back")
        XCTAssertTrue(browser.canReopenClosedWindow)
        // Back in the fixture space, the closed tab comes back.
        browser.select(try XCTUnwrap(browser.space(wired.spaceID)), in: main)
        browser.reopenClosedTab(in: main)
        XCTAssertTrue(wired.tabs.ordered.contains { $0.url == url(1) })
        // A window closed after that is what ⌘⇧T brings back in a space with no closed tab.
        let third = browser.newWindow(space: "other")
        browser.windowWillClose(third)
        browser.select(try XCTUnwrap(browser.space("other")), in: main)
        browser.reopenClosedTab(in: main)
        XCTAssertEqual(browser.windows.count, windows + 1, "the window closed last came back")
        // Pages still on their way finish before tearDown deletes the stores.
        _ = await eventually { browser.windows.flatMap(\.allTabs).allSatisfy { !$0.isBuilding } }
    }
}
