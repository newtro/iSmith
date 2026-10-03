@testable import Blocking
import Foundation
import WebKit
import XCTest

/// Real page loads in WKWebView against a local server. 127.0.0.1 and localhost are the same
/// server under two site names, so one can be allowlisted and the other not.
@MainActor
final class WebViewTests: XCTestCase {
    private var server: TestServer!
    private var dir: TempDir!

    private static let page = """
        <!doctype html><html><body>
        <div class="ad-banner" id="banner">ad</div>
        <script>window.adLoaded = false; window.newAdLoaded = false;</script>
        <script src="/ads/adbanner.js"></script>
        <script src="/ads/newad.js"></script>
        </body></html>
        """

    override func setUp() async throws {
        server = try TestServer(routes: [
            "/page.html": ("text/html", Self.page),
            "/ads/adbanner.js": ("text/javascript", "window.adLoaded = true;"),
            "/ads/newad.js": ("text/javascript", "window.newAdLoaded = true;"),
        ])
        try await server.start()
        dir = try TempDir()
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        dir = nil
    }

    private func pageURL(_ host: String) -> URL {
        URL(string: "http://\(host):\(server.port)/page.html")!
    }

    /// A controller whose only list is the fixture list (blocks /ads/adbanner.js, hides .ad-banner).
    private func fixtureController(fetch: FakeFetcher? = nil, sources: [FilterSource]? = nil) throws -> BlockingController {
        var config = BlockingController.Configuration(
            directory: dir.url.appendingPathComponent("Blocking"),
            sources: sources ?? [FilterSource(name: "fixture", url: URL(string: "https://lists.test/fixture.txt")!,
                                              bundled: Fixtures.fixtureURL)])
        config.minimumRulesPerSource = 1
        if let fetch { config.fetch = { try await fetch.fetch($0) } }
        return try BlockingController(configuration: config)
    }

    private struct PageResult: Equatable {
        var adLoaded: Bool
        var newAdLoaded: Bool
        var bannerHidden: Bool
    }

    private func inspect(_ webView: WKWebView) async throws -> PageResult {
        let ad = try await webView.evaluateJavaScript("window.adLoaded") as? Bool
        let newAd = try await webView.evaluateJavaScript("window.newAdLoaded") as? Bool
        let display = try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('banner')).display") as? String
        return PageResult(adLoaded: try XCTUnwrap(ad), newAdLoaded: try XCTUnwrap(newAd), bannerHidden: display == "none")
    }

    private func makeWebView(_ navigator: Navigator) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.navigationDelegate = navigator
        return webView
    }

    func testFixtureAdIsBlockedAndAnAllowlistedHostIsNot() async throws {
        let blocking = try fixtureController()
        try blocking.setAllowed(host: "localhost", true)
        let navigator = Navigator()

        let blocked = makeWebView(navigator)
        await blocking.apply(to: blocked.configuration.userContentController, host: "127.0.0.1")
        try await navigator.load(pageURL("127.0.0.1"), in: blocked)
        let page1 = try await inspect(blocked)
        XCTAssertEqual(page1, PageResult(adLoaded: false, newAdLoaded: true, bannerHidden: true))
        XCTAssertTrue(server.didRequest(host: "127.0.0.1", path: "/page.html"))
        XCTAssertFalse(server.didRequest(host: "127.0.0.1", path: "/ads/adbanner.js"), "the ad request never left WebKit")

        let allowed = makeWebView(navigator)
        await blocking.apply(to: allowed.configuration.userContentController, host: "localhost")
        try await navigator.load(pageURL("localhost"), in: allowed)
        let page2 = try await inspect(allowed)
        XCTAssertEqual(page2, PageResult(adLoaded: true, newAdLoaded: true, bannerHidden: false))
        XCTAssertTrue(server.didRequest(host: "localhost", path: "/ads/adbanner.js"))
    }

    /// The app's flow: lists applied when a main-frame navigation is decided, and the shield
    /// toggle re-applying and reloading. All in one web view.
    func testNavigationTimeApplyAndShieldToggleInOneWebView() async throws {
        let blocking = try fixtureController()
        try blocking.setAllowed(host: "localhost", true)
        let navigator = Navigator()
        navigator.blocking = blocking
        let webView = makeWebView(navigator)

        try await navigator.load(pageURL("127.0.0.1"), in: webView)
        let page3 = try await inspect(webView).adLoaded
        XCTAssertFalse(page3, "blocked site")

        try await navigator.load(pageURL("localhost"), in: webView)
        let page4 = try await inspect(webView).adLoaded
        XCTAssertTrue(page4, "navigated to an allowed site")

        try await navigator.load(pageURL("127.0.0.1"), in: webView)
        let page5 = try await inspect(webView).adLoaded
        XCTAssertFalse(page5, "back on a blocked site")

        // Shield off for 127.0.0.1, then reload.
        try blocking.setAllowed(host: "127.0.0.1", true)
        try await navigator.reload(webView)
        let page6 = try await inspect(webView)
        XCTAssertEqual(page6, PageResult(adLoaded: true, newAdLoaded: true, bannerHidden: false))

        // Shield back on.
        try blocking.setAllowed(host: "127.0.0.1", false)
        try await navigator.reload(webView)
        let page7 = try await inspect(webView)
        XCTAssertEqual(page7, PageResult(adLoaded: false, newAdLoaded: true, bannerHidden: true))
    }

    /// Settings' global switch: off takes the lists off (from the next load) without waiting for
    /// them, and posts `listsDidChange`; on puts them back. The allowlist is untouched.
    func testGlobalSwitchTurnsBlockingOffAndOn() async throws {
        let blocking = try fixtureController()
        let navigator = Navigator()
        navigator.blocking = blocking
        let webView = makeWebView(navigator)
        try await navigator.load(pageURL("127.0.0.1"), in: webView)
        let blockedFirst = try await inspect(webView).adLoaded
        XCTAssertFalse(blockedFirst)

        let changed = expectation(forNotification: BlockingController.listsDidChange, object: blocking)
        blocking.isEnabled = false
        await fulfillment(of: [changed], timeout: 1)
        XCTAssertTrue(blocking.applyIfLoaded(to: webView.configuration.userContentController, host: "127.0.0.1"))
        try await navigator.reload(webView)
        let off = try await inspect(webView)
        XCTAssertEqual(off, PageResult(adLoaded: true, newAdLoaded: true, bannerHidden: false))
        XCTAssertTrue(blocking.isBlocked(host: "127.0.0.1"), "the allowlist itself doesn't change")

        blocking.isEnabled = true
        try await navigator.reload(webView)
        let on = try await inspect(webView)
        XCTAssertEqual(on, PageResult(adLoaded: false, newAdLoaded: true, bannerHidden: true))
    }

    /// After a refresh, re-applying to an open web view swaps the old lists for the new ones.
    func testRefreshedListsReplaceTheOldOnesInAnOpenWebView() async throws {
        let fetcher = FakeFetcher()
        let source = FilterSource(name: "ads", url: URL(string: "https://lists.test/ads.txt")!,
                                  bundled: try dir.file("ads-v1.txt", "[Adblock Plus 2.0]\n! Version: 1\n/ads/adbanner.js\n"))
        fetcher.set(source.url, "[Adblock Plus 2.0]\n! Version: 2\n/ads/newad.js\n")
        let blocking = try fixtureController(fetch: fetcher, sources: [source])
        let navigator = Navigator()
        let webView = makeWebView(navigator)
        let content = webView.configuration.userContentController

        await blocking.apply(to: content, host: "127.0.0.1")
        try await navigator.load(pageURL("127.0.0.1"), in: webView)
        let page8 = try await inspect(webView)
        XCTAssertEqual(page8, PageResult(adLoaded: false, newAdLoaded: true, bannerHidden: false))

        let result = await blocking.refresh()
        XCTAssertEqual(result, .updated)
        XCTAssertTrue(blocking.applyIfLoaded(to: content, host: "127.0.0.1"))
        try await navigator.reload(webView)
        let page9 = try await inspect(webView)
        XCTAssertEqual(page9, PageResult(adLoaded: true, newAdLoaded: false, bannerHidden: false))
    }

    /// A navigation that's cancelled (an app link, a download) or fails before committing must
    /// leave the page on screen with its own setting, not the destination's.
    func testCancelledOrFailedNavigationKeepsTheCurrentPagesSetting() async throws {
        let blocking = try fixtureController()
        try blocking.setAllowed(host: "localhost", true)
        let navigator = Navigator()
        navigator.blocking = blocking
        let webView = makeWebView(navigator)
        try await navigator.load(pageURL("localhost"), in: webView)
        var probe = try await probeAd(webView)
        XCTAssertTrue(probe, "allowed site")

        // Cancelled by the app's policy: the lists for 127.0.0.1 were never attached.
        let decided = navigator.decisions
        _ = try await webView.evaluateJavaScript("location.href = 'http://127.0.0.1:\(server.port)/cancel.html'; 1")
        try await waitUntil("the cancel decision") { navigator.decisions > decided }
        probe = try await probeAd(webView)
        XCTAssertTrue(probe, "still on the allowed site after a cancelled navigation")

        // Allowed, so 127.0.0.1's lists were attached, but the load fails before committing.
        let failed = navigator.provisionalFailures
        _ = try await webView.evaluateJavaScript("location.href = 'http://127.0.0.1:1/page.html'; 1")
        try await waitUntil("the failed navigation") { navigator.provisionalFailures > failed }
        XCTAssertEqual(webView.url?.host, "localhost")
        probe = try await probeAd(webView)
        XCTAssertTrue(probe, "still on the allowed site after a failed navigation")
    }

    /// A navigation replaced while still loading fails after the new one has applied its
    /// setting; that failure must not put the old page's setting back over the new one's.
    func testReplacedNavigationKeepsTheNewDestinationsSetting() async throws {
        server.hangingPaths = ["/slow.html"]
        let blocking = try fixtureController()
        try blocking.setAllowed(host: "localhost", true)
        let navigator = Navigator()
        navigator.blocking = blocking
        let webView = makeWebView(navigator)
        try await navigator.load(pageURL("localhost"), in: webView)

        // Start a load that never finishes, on a blocked host…
        let decided = navigator.decisions
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/slow.html")!))
        try await waitUntil("the slow navigation") { navigator.decisions > decided && server.didRequest(host: "127.0.0.1", path: "/slow.html") }
        // …then go to another blocked page before it commits.
        let failures = navigator.provisionalFailures
        try await navigator.load(pageURL("127.0.0.1"), in: webView)
        XCTAssertGreaterThan(navigator.provisionalFailures, failures, "the slow navigation was cancelled")
        let page = try await inspect(webView)
        XCTAssertEqual(page, PageResult(adLoaded: false, newAdLoaded: true, bannerHidden: true))
    }

    /// Loads the ad script again from the current page; true if it loaded.
    private var probes = 0
    private func probeAd(_ webView: WKWebView) async throws -> Bool {
        probes += 1
        let result = try await webView.callAsyncJavaScript("""
            return await new Promise(resolve => {
                const s = document.createElement('script');
                s.src = '/ads/adbanner.js?probe=' + n;
                s.onload = () => resolve(true);
                s.onerror = () => resolve(false);
                document.head.appendChild(s);
            });
            """, arguments: ["n": probes], contentWorld: .page)
        return try XCTUnwrap(result as? Bool)
    }
}

/// Waits for navigations and, when `blocking` is set, follows INTEGRATION.md's navigation
/// delegate: decide the policy first, apply blocking only to a navigation that's allowed, and
/// re-apply the committed page's setting when a navigation fails before committing.
@MainActor
final class Navigator: NSObject, WKNavigationDelegate {
    var blocking: BlockingController?
    /// Paths the delegate cancels, standing in for app links and downloads.
    var cancelledPaths: Set<String> = ["/cancel.html"]
    private(set) var decisions = 0
    private(set) var provisionalFailures = 0
    private var committedHost: String?
    /// The navigation a test is waiting for, so another navigation ending doesn't count.
    private var waiting: (navigation: WKNavigation?, continuation: CheckedContinuation<Void, Error>)?

    func load(_ url: URL, in webView: WKWebView) async throws {
        try await wait { webView.load(URLRequest(url: url)) }
    }

    func reload(_ webView: WKWebView) async throws {
        try await wait { webView.reload() }
    }

    private func wait(_ start: () -> WKNavigation?) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiting = (nil, continuation)
            waiting?.navigation = start()
        }
    }

    private func finish(_ navigation: WKNavigation?, _ error: Error?) {
        guard let waiting, waiting.navigation == nil || waiting.navigation === navigation else { return }
        self.waiting = nil
        if let error { waiting.continuation.resume(throwing: error) } else { waiting.continuation.resume() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 preferences: WKWebpagePreferences) async -> (WKNavigationActionPolicy, WKWebpagePreferences) {
        defer { decisions += 1 }
        if let path = navigationAction.request.url?.path, cancelledPaths.contains(path) {
            return (.cancel, preferences)
        }
        if let blocking, navigationAction.targetFrame?.isMainFrame == true {
            await blocking.apply(to: webView.configuration.userContentController, host: navigationAction.request.url?.host)
        }
        return (.allow, preferences)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        committedHost = webView.url?.host
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finish(navigation, nil) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(navigation, error)
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        provisionalFailures += 1
        // The page on screen is still the committed one: put its setting back, unless a newer
        // navigation replaced this one and has already applied its own.
        if !webView.isLoading {
            blocking?.applyIfLoaded(to: webView.configuration.userContentController, host: committedHost)
        }
        finish(navigation, error)
    }
}

/// Polls the main actor until `condition` holds, for up to 10 seconds.
@MainActor
func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(10)
    while !condition() {
        guard Date() < deadline else { throw TimedOut(what: what) }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

struct TimedOut: Error { let what: String }
