import Blocking
import SignInSync
import WebKit
import XCTest
@testable import iSmith

/// P8 integration: every way the app makes a web view gives it the same equipment. For each
/// path (new tab, popup, duplicate, reopened tab, Keep alive rebuild, hibernated tab coming back,
/// restored tab, restored Keep alive tab, tab moved to a new window or another space, routed link
/// from another app, a tab opened during an account switch and the pages it parked) the page
/// must load with:
/// - the space's own data store;
/// - Safari's user agent (Google's sign-in needs it);
/// - the notification shim in the page and its bridge;
/// - password autofill and the context-menu reporter;
/// - the blocking lists (a fixture ad script is blocked and `.ad-banner` hidden).
@MainActor
final class WebViewPathsTests: XCTestCase {
    private var server: TestHTTPServer!
    private var wired: WiredBrowser!
    private let other = "other"

    private static let page = """
        <!doctype html><title>Page</title><body>
        <div class="ad-banner" id="banner">ad</div>
        <script>window.adLoaded = false;</script>
        <script src="/ads/adbanner.js"></script>
        </body>
        """

    override func setUp() async throws {
        server = try TestHTTPServer(routes: [
            "/page.html": .html(Self.page),
            "/next.html": .html(Self.page),
            "/ads/adbanner.js": .init(type: "text/javascript", body: Data("window.adLoaded = true;".utf8)),
        ])
        try await server.start()
        wired = try WiredBrowser(extraSpaces: [other]) { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let list = dir.appendingPathComponent("fixture.txt")
            try Data("[Adblock Plus 2.0]\n! Title: app test list\n! Version: 1\n/ads/adbanner.js\n##.ad-banner\n".utf8).write(to: list)
            var config = BlockingController.Configuration(
                directory: dir, sources: [FilterSource(name: "fixture", url: URL(string: "https://lists.test/fixture.txt")!, bundled: list)])
            config.minimumRulesPerSource = 1
            return try BlockingController(configuration: config)
        }
    }

    override func tearDown() async throws {
        await wired?.tearDown()
        server?.stop()
    }

    private func url(_ path: String = "/page.html") -> URL {
        URL(string: "http://127.0.0.1:\(server.port)\(path)")!
    }

    /// The paths checked, in order, so a run lists what it covered.
    private var checked: [String] = []

    /// Waits for `tab` to show `path`, then checks everything a web view must have.
    private func verify(_ name: String, _ tab: Tab, space: String, path: String = "/page.html",
                        file: StaticString = #filePath, line: UInt = #line) async throws {
        try await wired.waitForLoad(tab, path: path, file: file, line: line)
        let browser = wired.browser
        let webView = try XCTUnwrap(tab.webView, "\(name): a web view", file: file, line: line)
        let store = try XCTUnwrap(browser.space(space)?.def.storeID)
        XCTAssertEqual(webView.configuration.websiteDataStore.identifier, store, "\(name): the space's data store", file: file, line: line)
        XCTAssertEqual(browser.owner(of: webView)?.1.spaceID, space, "\(name): in that space's tabs", file: file, line: line)

        XCTAssertEqual(webView.customUserAgent, BrowserState.userAgent, "\(name): Safari's user agent", file: file, line: line)
        let agent = try await webView.evaluateJavaScript("navigator.userAgent") as? String
        XCTAssertEqual(agent, BrowserState.userAgent, "\(name): the page sees Safari's user agent", file: file, line: line)

        let scripts = webView.configuration.userContentController.userScripts
        XCTAssertTrue(scripts.contains { $0.source.contains(browser.notifications.channel) }, "\(name): notification shim", file: file, line: line)
        let shim = try await webView.evaluateJavaScript("String(Notification).startsWith('class') && Notification.maxActions === 0") as? Bool
        XCTAssertEqual(shim, true, "\(name): the page's Notification is iSmith's", file: file, line: line)
        XCTAssertTrue(scripts.contains { $0.source.contains("ismithPasswords") }, "\(name): password autofill", file: file, line: line)
        XCTAssertEqual(browser.passwords?.isDisabled(for: webView), false, "\(name): autofill is on", file: file, line: line)
        XCTAssertTrue(scripts.contains { $0.source.contains("ismithContext") }, "\(name): context-menu reporter", file: file, line: line)

        let ad = try await webView.evaluateJavaScript("window.adLoaded") as? Bool
        let display = try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('banner')).display") as? String
        XCTAssertEqual(ad, false, "\(name): the ad script is blocked", file: file, line: line)
        XCTAssertEqual(display, "none", "\(name): the ad banner is hidden", file: file, line: line)
        checked.append(name)
    }

    /// At launch the filter lists may still be loading when restored tabs are built, and a
    /// restored history can load without asking the navigation delegate. The web view gets the
    /// lists before its first load anyway.
    func testARestoredTabIsBlockedBeforeTheListsHaveLoaded() async throws {
        XCTAssertNil(wired.browser.shields.controller?.loadedRuleLists, "the lists haven't loaded yet")
        // A back/forward history from a plain web view.
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let plain = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = NavigationWaiter()
        plain.navigationDelegate = waiter
        plain.load(URLRequest(url: url()))
        await waiter.next()
        let history = try XCTUnwrap(plain.interactionState as? Data)

        let id = UUID()
        let window = wired.browser.restoreWindow(WindowRecord(id: UUID(), frame: nil, activeSpace: wired.spaceID, spaces: [
            SpaceRecord(space: wired.spaceID, selected: id, groups: [], tabs: [
                TabRecord(id: id, url: url(), title: "Page", group: nil, keepAlive: nil, history: history),
            ]),
        ]))
        let tab = try XCTUnwrap(window.spaces[wired.spaceID]?.tab(id))
        try await verify("restored tab at launch", tab, space: wired.spaceID)
    }

    func testEveryWayToMakeAWebViewIsFullyWired() async throws {
        let lists = await wired.browser.shields.controller?.ruleLists()
        XCTAssertEqual(lists?.count, 1, "the fixture list compiled")
        let browser = wired.browser
        let window = wired.window
        let tabs = wired.tabs
        let fixture = wired.spaceID

        // A new tab.
        let first = browser.openTab(in: window, space: fixture, url: url())
        try await verify("new tab", first, space: fixture)

        // A popup (window.open): WebKit's configuration with the opener's store, its own controller.
        _ = try await first.webView?.evaluateJavaScript("window.open('\(url("/next.html").absoluteString)'); 1")
        let opened = await eventually { tabs.ordered.contains { $0.openerID == first.id } }
        XCTAssertTrue(opened, "the popup opened as a tab")
        let popup = try XCTUnwrap(tabs.ordered.first { $0.openerID == first.id })
        try await verify("popup", popup, space: fixture, path: "/next.html")
        browser.closeTab(popup.id, in: tabs)

        // A duplicate: a new web view from another's back/forward history.
        browser.duplicate(first.id, in: tabs, window: window)
        let duplicate = try XCTUnwrap(tabs.selected)
        XCTAssertFalse(duplicate === first)
        try await verify("duplicated tab", duplicate, space: fixture)

        // ⌘⇧T: a closed tab comes back with its history.
        browser.closeTab(duplicate.id, in: tabs)
        browser.reopenClosedTab(in: window)
        let reopened = try XCTUnwrap(tabs.selected)
        XCTAssertFalse(reopened === first)
        try await verify("reopened closed tab", reopened, space: fixture)

        // Keep alive switched on from the context menu: a new web view with the new policy.
        let before = try XCTUnwrap(reopened.webView)
        browser.setKeepAlive(true, for: reopened, in: tabs)
        let rebuilt = await eventually { reopened.webView != nil && reopened.webView !== before }
        XCTAssertTrue(rebuilt, "Keep alive made a new web view")
        XCTAssertEqual(reopened.webView?.configuration.preferences.inactiveSchedulingPolicy, WKPreferences.InactiveSchedulingPolicy.none)
        try await verify("Keep alive rebuild", reopened, space: fixture)

        // Hibernation: the first tab, long in the background, is unloaded and comes back when selected.
        XCTAssertEqual(tabs.layout.selected, reopened.id)
        first.lastShown = Date().addingTimeInterval(-BrowserState.hibernateAfter - 60)
        browser.hibernateIdleTabs()
        let unloaded = await eventually { first.webView == nil }
        XCTAssertTrue(unloaded, "the idle tab was unloaded")
        XCTAssertNotNil(first.savedState, "with its history")
        browser.selectTab(first.id, in: tabs)
        try await verify("hibernated tab reloaded", first, space: fixture)

        // Session restore: a window from saved records; the selected tab and a Keep alive tab load.
        let history = try XCTUnwrap(first.history)
        let restoredID = UUID(), keptID = UUID()
        let record = WindowRecord(id: UUID(), frame: nil, activeSpace: fixture, spaces: [
            SpaceRecord(space: fixture, selected: restoredID, groups: [], tabs: [
                TabRecord(id: restoredID, url: url(), title: "Page", group: nil, keepAlive: nil, history: history),
                TabRecord(id: keptID, url: url("/next.html"), title: "Kept", group: nil, keepAlive: true, history: nil),
            ]),
        ])
        let restoredWindow = browser.restoreWindow(record)
        let restoredTabs = try XCTUnwrap(restoredWindow.spaces[fixture])
        try await verify("restored tab", try XCTUnwrap(restoredTabs.tab(restoredID)), space: fixture)
        try await verify("restored Keep alive tab", try XCTUnwrap(restoredTabs.tab(keptID)), space: fixture, path: "/next.html")

        // A tab moved to a new window keeps its web view, still fully equipped.
        browser.moveToNewWindow(restoredID, from: restoredTabs, in: restoredWindow)
        let moved = try XCTUnwrap(browser.windows.compactMap { $0.spaces[fixture]?.tab(restoredID) }.first)
        try await verify("tab moved to a new window", moved, space: fixture)

        // A tab moved to another space reloads in that space's store.
        browser.moveTab(first.id, from: (window, fixture), to: (window, other), before: nil, group: nil)
        try await verify("tab moved to another space", first, space: other)

        // A link from another app, routed to the Default space ("other").
        browser.routing.store.setDefaultSpace(other)
        let incoming = try XCTUnwrap(browser.openIncoming(url("/next.html")))
        try await verify("routed incoming link", incoming.tab, space: other, path: "/next.html")

        // An account switch in "other": its pages are parked and reload afterwards, and a tab
        // opened meanwhile waits for the switch.
        let parkedBefore = try XCTUnwrap(incoming.tab.webView)
        _ = try await parkedBefore.evaluateJavaScript("window.__iSmithOldPage = true; 1")
        browser.applySpaceUpdate(other, name: "Other", color: 1, home: "", choices: ["google": .local], newNames: [:])
        let during = browser.openTab(in: incoming.window, space: other, url: url())
        try await verify("tab opened during an account switch", during, space: other)
        XCTAssertEqual(browser.config.space(other)?.bindings["google"], SpaceDef.local, "the switch happened")
        let reloaded = await eventually {
            guard incoming.tab.webView?.url?.path == "/next.html" else { return false }
            return (try? await incoming.tab.webView?.evaluateJavaScript("window.__iSmithOldPage !== true && document.readyState === 'complete'") as? Bool) == true
        }
        XCTAssertTrue(reloaded, "the parked page came back")
        XCTAssertTrue(incoming.tab.webView === parkedBefore, "in the same web view")
        try await verify("page parked by an account switch", incoming.tab, space: other, path: "/next.html")

        XCTAssertEqual(checked, [
            "new tab", "popup", "duplicated tab", "reopened closed tab", "Keep alive rebuild",
            "hibernated tab reloaded", "restored tab", "restored Keep alive tab", "tab moved to a new window",
            "tab moved to another space", "routed incoming link", "tab opened during an account switch",
            "page parked by an account switch",
        ])
    }
}
