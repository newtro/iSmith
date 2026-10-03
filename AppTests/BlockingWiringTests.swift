import Blocking
import WebKit
import XCTest
@testable import iSmith

/// P3 wiring: blocking applied through the app's navigation delegate, the shield's per-site
/// allowlist with its reload, popups getting their own content controller, and the global switch.
/// 127.0.0.1 and localhost are one local server under two site names.
@MainActor
final class BlockingWiringTests: XCTestCase {
    private var server: TestHTTPServer!
    private var wired: WiredBrowser!
    private var blocking: BlockingController!

    private static let page = """
        <!doctype html><title>Ads</title><body>
        <div class="ad-banner" id="banner">ad</div>
        <script>window.adLoaded = false;</script>
        <script src="/ads/adbanner.js"></script>
        </body>
        """

    override func setUp() async throws {
        server = try TestHTTPServer(routes: [
            "/page.html": .html(Self.page),
            "/other.html": .html(Self.page),
            "/ads/adbanner.js": .init(type: "text/javascript", body: Data("window.adLoaded = true;".utf8)),
        ])
        try await server.start()
        wired = try WiredBrowser { dir in
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let list = dir.appendingPathComponent("fixture.txt")
            try Data("[Adblock Plus 2.0]\n! Title: app test list\n! Version: 1\n/ads/adbanner.js\n##.ad-banner\n".utf8).write(to: list)
            var config = BlockingController.Configuration(
                directory: dir, sources: [FilterSource(name: "fixture", url: URL(string: "https://lists.test/fixture.txt")!, bundled: list)])
            config.minimumRulesPerSource = 1
            return try BlockingController(configuration: config)
        }
        blocking = try XCTUnwrap(wired.browser.shields.controller)
        let lists = await blocking.ruleLists()
        XCTAssertEqual(lists.count, 1, "the fixture list compiled")
    }

    override func tearDown() async throws {
        await wired?.tearDown()
        server?.stop()
    }

    private func url(_ host: String, _ path: String = "/page.html") -> URL {
        URL(string: "http://\(host):\(server.port)\(path)")!
    }

    private struct PageState: Equatable {
        var adLoaded: Bool
        var bannerHidden: Bool
    }

    private func state(_ tab: Tab) async throws -> PageState {
        let webView = try XCTUnwrap(tab.webView)
        let ad = try await webView.evaluateJavaScript("window.adLoaded") as? Bool
        let display = try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('banner')).display") as? String
        return PageState(adLoaded: try XCTUnwrap(ad), bannerHidden: display == "none")
    }

    private let blocked = PageState(adLoaded: false, bannerHidden: true)
    private let allowed = PageState(adLoaded: true, bannerHidden: false)

    func testShieldAllowlistsTheSiteAndReloadsItsTabs() async throws {
        let browser = wired.browser
        let tab = try await wired.open(url("127.0.0.1"))
        let first = try await state(tab)
        XCTAssertEqual(first, blocked, "blocked through the navigation delegate")
        XCTAssertEqual(browser.shields.isBlocked(tab.url), true)
        XCTAssertEqual(tab.committedHost, "127.0.0.1")

        // Another site in another tab, and a second tab on the same site.
        let other = try await wired.open(url("localhost"))
        let sameSite = try await wired.open(url("127.0.0.1", "/other.html"))
        // A Keep alive tab of the site (Outlook, a Teams call) isn't reloaded under the user.
        let keptAlive = try await wired.open(url("127.0.0.1", "/other.html"))
        keptAlive.keepAliveSetting = true
        _ = try await keptAlive.webView?.evaluateJavaScript("window.__iSmithOldPage = true; 1")

        // The shield: off for 127.0.0.1. Both of that site's tabs reload unblocked; localhost doesn't.
        try await wired.waitForNewPage(tab, path: "/page.html") { browser.toggleBlocking(for: tab) }
        XCTAssertEqual(browser.shields.isBlocked(tab.url), false)
        XCTAssertEqual(browser.shields.allowedSites, ["127.0.0.1"])
        let afterToggle = try await state(tab)
        XCTAssertEqual(afterToggle, allowed)
        let reloadedSameSite = await eventually { (try? await self.state(sameSite)) == self.allowed }
        XCTAssertTrue(reloadedSameSite, "the site's other tab reloaded without blocking")
        let untouched = try await state(other)
        XCTAssertEqual(untouched, blocked, "another site keeps blocking")
        let notReloaded = try await keptAlive.webView?.evaluateJavaScript("window.__iSmithOldPage === true") as? Bool
        XCTAssertEqual(notReloaded, true, "the Keep alive tab wasn't reloaded")
        try await wired.waitForNewPage(keptAlive, path: "/other.html") { keptAlive.webView?.reload() }
        let keptAliveState = try await state(keptAlive)
        XCTAssertEqual(keptAliveState, allowed, "it has the new setting from its next load")

        // Navigating that tab to the blocked site applies the destination's setting.
        try await wired.waitForNewPage(other, path: "/page.html") { other.webView?.load(URLRequest(url: url("127.0.0.1"))) }
        let navigated = try await state(other)
        XCTAssertEqual(navigated, allowed)
        try await wired.waitForNewPage(other, path: "/page.html") { other.webView?.load(URLRequest(url: url("localhost"))) }
        let back = try await state(other)
        XCTAssertEqual(back, blocked)

        // Shield back on.
        try await wired.waitForNewPage(tab, path: "/page.html") { browser.toggleBlocking(for: tab) }
        let on = try await state(tab)
        XCTAssertEqual(on, blocked)
        XCTAssertEqual(browser.shields.allowedSites, [])
    }

    /// A popup gets its own content controller (WebKit hands it the opener's), so the opener's
    /// shield doesn't decide the popup's blocking.
    func testPopupsGetTheirOwnContentController() async throws {
        let browser = wired.browser
        try blocking.setAllowed(host: "127.0.0.1", true)
        let opener = try await wired.open(url("127.0.0.1"))
        let openerState = try await state(opener)
        XCTAssertEqual(openerState, allowed)

        _ = try await opener.webView?.evaluateJavaScript("window.open('\(url("localhost").absoluteString)'); 1")
        let appeared = await eventually { self.wired.tabs.ordered.contains { $0.openerID == opener.id } }
        XCTAssertTrue(appeared)
        let popup = try XCTUnwrap(wired.tabs.ordered.first { $0.openerID == opener.id })
        try await wired.waitForLoad(popup, path: "/page.html")
        XCTAssertFalse(popup.webView?.configuration.userContentController === opener.webView?.configuration.userContentController)
        let popupState = try await state(popup)
        XCTAssertEqual(popupState, blocked, "the popup's site is blocked even though the opener's isn't")
        XCTAssertEqual(browser.shields.isBlocked(popup.url), true)

        // The app's scripts are in the popup's own controller too (notifications, context menu, autofill).
        let scripts = try XCTUnwrap(popup.webView?.configuration.userContentController.userScripts)
        XCTAssertTrue(scripts.contains { $0.source.contains("ismithContext") })
        XCTAssertTrue(scripts.contains { $0.source.contains("ismithPasswords") })
    }

    /// Settings' switch turns blocking off everywhere from each page's next load, and back on.
    func testGlobalSwitch() async throws {
        let browser = wired.browser
        let tab = try await wired.open(url("127.0.0.1"))
        let on = try await state(tab)
        XCTAssertEqual(on, blocked)

        browser.shields.setEnabled(false, defaults: wired.defaults)
        XCTAssertEqual(browser.shields.isBlocked(tab.url), false, "the shield shows blocking off")
        try await wired.waitForNewPage(tab, path: "/page.html") { tab.webView?.reload() }
        let off = try await state(tab)
        XCTAssertEqual(off, allowed)
        let newTab = try await wired.open(url("localhost"))
        let newOff = try await state(newTab)
        XCTAssertEqual(newOff, allowed, "new pages aren't blocked either")

        browser.shields.setEnabled(true, defaults: wired.defaults)
        XCTAssertEqual(wired.defaults.object(forKey: Shields.enabledKey) as? Bool, true)
        try await wired.waitForNewPage(tab, path: "/page.html") { tab.webView?.reload() }
        let back = try await state(tab)
        XCTAssertEqual(back, blocked)
    }

    /// A navigation that fails before committing puts the page's own setting back: the page on
    /// screen keeps loading what it loads (here, an ad script it adds afterwards) by its own rules.
    func testFailedNavigationKeepsThePagesSetting() async throws {
        try blocking.setAllowed(host: "127.0.0.1", true)
        let tab = try await wired.open(url("127.0.0.1"))
        // Port 9 on localhost (a blocked site): nothing listens, so it fails before committing.
        tab.webView?.load(URLRequest(url: URL(string: "http://localhost:9/nothing")!))
        try await Task.sleep(nanoseconds: 200_000_000)
        let failed = await eventually { tab.webView?.isLoading == false }
        XCTAssertTrue(failed)
        XCTAssertEqual(tab.webView?.url?.host, "127.0.0.1", "the page on screen is still the allowed one")
        _ = try await tab.webView?.evaluateJavaScript("""
            window.adLoaded = false;
            const s = document.createElement('script'); s.src = '/ads/adbanner.js?again'; document.body.appendChild(s); 1
            """)
        let loaded = await eventually { (try? await tab.webView?.evaluateJavaScript("window.adLoaded") as? Bool) == true }
        XCTAssertTrue(loaded, "the failed navigation's (blocked) setting didn't stick to the page on screen")
    }
}
