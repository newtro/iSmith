@testable import Blocking
import WebKit
import XCTest

/// Pages, popups and rules without a type. In Adblock Plus only `$document` and `$popup` block a
/// page; WebKit reads a rule with no resource type as every type. Outlook opens mail links with
/// `window.open`, and `||urldefense.com^$third-party` (EasyPrivacy) stopped Proofpoint-wrapped
/// links from opening.
@MainActor
final class PopupTests: XCTestCase, WKUIDelegate, WKNavigationDelegate {
    private var server: TestServer!
    private var dir: TempDir!
    private var popups: [WKWebView] = []
    private var popupLoaded = false

    override func setUp() async throws {
        server = try TestServer(routes: [
            "/page.html": ("text/html", "<!doctype html><html><body>page</body></html>"),
            "/dest.html": ("text/html", "<!doctype html><html><body>dest</body></html>"),
            "/tracker.js": ("text/javascript", "window.trackerRan = true;"),
            "/pixel.json": ("application/json", "{}"),
            "/frame.html": ("text/html", "<!doctype html><html><body>frame</body></html>"),
        ])
        try await server.start()
        dir = try TempDir()
    }

    override func tearDown() async throws {
        server.stop()
        server = nil
        dir = nil
        popups = []
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 300, height: 200), configuration: configuration)
        popup.navigationDelegate = self
        popups.append(popup)
        return popup
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if popups.contains(webView), webView.url?.path == "/dest.html" { popupLoaded = true }
    }

    /// A page on 127.0.0.1 under `filters`, which name localhost (the same server, another site).
    private func page(_ filters: String) async throws -> WKWebView {
        let lists = try RuleListBuilder.build(sources: [("test", filters)])
        let store = try await WebKitRuleListStore(directory: dir.url)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        for list in lists {
            configuration.userContentController.add(try await store.compile(identifier: list.name, json: list.json))
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        webView.uiDelegate = self
        let navigator = Loader()
        webView.navigationDelegate = navigator
        webView.load(URLRequest(url: URL(string: "http://127.0.0.1:\(server.port)/page.html")!))
        try await navigator.wait()
        return webView
    }

    private var localhost: String { "http://localhost:\(server.port)" }

    func testUntypedThirdPartyRuleLetsWindowOpenThroughButStillBlocksLoads() async throws {
        let webView = try await page("||localhost^$third-party")
        _ = try? await webView.evaluateJavaScript("window.open('\(localhost)/dest.html', '_blank')")
        try await waitUntil("the popup loads") { popupLoaded }

        // Subresources from the blocked host are still blocked.
        let fetched = try await webView.callAsyncJavaScript("""
            try { await fetch(url); return 'loaded' } catch (e) { return 'blocked' }
            """, arguments: ["url": "\(localhost)/pixel.json"], contentWorld: .page) as? String
        XCTAssertEqual(fetched, "blocked")
        let script = try await webView.callAsyncJavaScript("""
            return await new Promise(done => { const s = document.createElement('script'); s.src = url;
              s.onload = () => done('loaded'); s.onerror = () => done('blocked'); document.body.appendChild(s) })
            """, arguments: ["url": "\(localhost)/tracker.js"], contentWorld: .page) as? String
        XCTAssertEqual(script, "blocked")
        XCTAssertFalse(server.requests.contains { $0.path == "/pixel.json" || $0.path == "/tracker.js" })
    }

    func testUntypedRuleBlocksFramesButNotPagesInTabs() async throws {
        let webView = try await page("||localhost^")
        // An iframe from the host is still blocked.
        let frame = try await webView.callAsyncJavaScript("""
            return await new Promise(done => { const f = document.createElement('iframe'); f.src = url;
              f.onload = () => { try { done(f.contentDocument ? 'blocked' : 'loaded') } catch (e) { done('loaded') } };
              document.body.appendChild(f); setTimeout(() => done('timeout'), 3000) })
            """, arguments: ["url": "\(localhost)/frame.html"], contentWorld: .page) as? String
        XCTAssertNotEqual(frame, "loaded")
        XCTAssertFalse(server.requests.contains { $0.path == "/frame.html" }, "the frame was never requested")

        // A popup and the tab's own page aren't.
        _ = try? await webView.evaluateJavaScript("window.open('\(localhost)/dest.html', '_blank')")
        try await waitUntil("the popup loads") { popupLoaded }
        let navigator = Loader()
        webView.navigationDelegate = navigator
        webView.load(URLRequest(url: URL(string: "\(localhost)/page.html")!))
        try await navigator.wait()
        XCTAssertEqual(webView.url?.host, "localhost")
    }

    func testNegatedTypeRuleLetsWindowOpenThrough() async throws {
        let webView = try await page("||localhost^$~subdocument,third-party")
        _ = try? await webView.evaluateJavaScript("window.open('\(localhost)/dest.html', '_blank')")
        try await waitUntil("the popup loads") { popupLoaded }
    }

    func testExplicitPopupRuleStillBlocksWindowOpen() async throws {
        let webView = try await page("||localhost^$popup")
        _ = try? await webView.evaluateJavaScript("window.open('\(localhost)/dest.html', '_blank')")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(popupLoaded)
        XCTAssertFalse(server.requests.contains { $0.path == "/dest.html" })
    }

    func testOnlyUntypedBlockingRulesAreSplit() throws {
        let lists = try RuleListBuilder.build(sources: [("test", """
            ||untyped.example^$third-party
            ||images.example^$image
            ||popups.example^$popup
            ||noimage.example^$~image,third-party
            ||topframe.example^$~subdocument,third-party
            @@||untyped.example/ok.js
            ##.ad-banner
            """)])
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lists[0].json.utf8)) as? [[String: Any]])
        func triggers(_ host: String, _ action: String) -> [[String: Any]] {
            rules.compactMap { rule in
                guard (rule["action"] as? [String: Any])?["type"] as? String == action,
                      let trigger = rule["trigger"] as? [String: Any],
                      (trigger["url-filter"] as? String ?? "").contains(host) else { return nil }
                return trigger
            }
        }
        let untyped = triggers("untyped", "block")
        XCTAssertEqual(untyped.map { $0["resource-type"] as? [String] }, [RuleListBuilder.subresourceTypes, ["document"]])
        XCTAssertEqual(untyped.map { $0["load-context"] as? [String] }, [nil, ["child-frame"]])
        XCTAssertTrue(untyped.allSatisfy { $0["load-type"] as? [String] == ["third-party"] }, "the rest of the trigger is kept")
        // "Every type but X" comes from the converter with "document" in it; it goes the same way.
        let noImage = triggers("noimage", "block")
        XCTAssertEqual(noImage.count, 2)
        XCTAssertFalse(noImage[0]["resource-type"] as? [String] == nil || (noImage[0]["resource-type"] as! [String]).contains("document"))
        XCTAssertFalse((noImage[0]["resource-type"] as? [String] ?? []).contains("image"))
        XCTAssertEqual(noImage[1]["resource-type"] as? [String], ["document"])
        XCTAssertEqual(noImage[1]["load-context"] as? [String], ["child-frame"])
        // Not in frames: only top frames, so no twin.
        let topFrame = triggers("topframe", "block")
        XCTAssertEqual(topFrame.count, 1)
        XCTAssertFalse((topFrame[0]["resource-type"] as? [String] ?? ["document"]).contains("document"))
        XCTAssertEqual(triggers("images", "block").map { $0["resource-type"] as? [String] }, [["image"]])
        XCTAssertEqual(triggers("popups", "block").map { $0["resource-type"] as? [String] }, [["document"]], "$popup as the converter writes it")
        XCTAssertEqual(triggers("untyped", "ignore-previous-rules").map { $0["resource-type"] == nil }, [true],
                       "exceptions keep covering every type")
        XCTAssertEqual(lists[0].ruleCount, rules.count)
        let hiding = rules.first { ($0["action"] as? [String: Any])?["type"] as? String == "css-display-none" }
        XCTAssertNil((hiding?["trigger"] as? [String: Any])?["resource-type"])
    }
}

/// Waits for a web view's first page to finish.
@MainActor
private final class Loader: NSObject, WKNavigationDelegate {
    private var done = false
    private var error: Error?

    func wait() async throws {
        try await waitUntil("the page loads") { done }
        if let error { throw error }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done = true }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error
        done = true
    }
}
