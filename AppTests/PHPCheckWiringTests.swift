import WebKit
import XCTest
@testable import iSmith
import SiteCheck

/// The PHP2Shell check reads the headers of the page and its same-origin frames, and warns once
/// when a password field gets focus on a site that reports an unpatched PHP.
@MainActor
final class PHPCheckWiringTests: XCTestCase {
    private var server: TestHTTPServer!
    private var wired: WiredBrowser!

    private static let form = "<title>Login</title><input id=name name=user><input id=pw type=password>"

    override func setUp() async throws {
        server = try TestHTTPServer(routes: [
            "/old.html": .init(headers: ["X-Powered-By": "PHP/8.3.20"], body: Data(Self.form.utf8)),
            "/new.html": .init(headers: ["X-Powered-By": "PHP/8.4.30"], body: Data(Self.form.utf8)),
            "/plain.html": .html("<title>Plain</title><p>plain"),
            "/session.html": .init(headers: ["Set-Cookie": "PHPSESSID=abc; path=/"], body: Data("<p>session".utf8)),
            "/framed.html": .html("<title>Framed</title><iframe src=/legacy.php></iframe>"),
            "/legacy.php": .init(headers: ["X-Powered-By": "PHP/7.4.3"], body: Data("<p>legacy".utf8)),
        ])
        try await server.start()
        wired = try WiredBrowser()
    }

    override func tearDown() async throws {
        await wired?.tearDown()
        server?.stop()
    }

    private func focus(_ id: String, in tab: Tab) async throws {
        _ = try await tab.webView?.evaluateJavaScript("document.getElementById('\(id)').focus(); 1")
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    func testVerdictFollowsThePageOnScreen() async throws {
        let tab = try await wired.open(server.url("/old.html"))
        XCTAssertEqual(tab.phpCheck?.verdict.level, .vulnerable)
        XCTAssertEqual(tab.phpCheck?.verdict.version, "8.3.20")
        XCTAssertEqual(tab.phpCheck?.origin, server.origin)

        try await wired.waitForNewPage(tab, path: "/new.html") { tab.webView?.load(URLRequest(url: server.url("/new.html"))) }
        XCTAssertEqual(tab.phpCheck?.verdict.level, .patched)

        try await wired.waitForNewPage(tab, path: "/plain.html") { tab.webView?.load(URLRequest(url: server.url("/plain.html"))) }
        XCTAssertEqual(tab.phpCheck?.verdict.level, .noPHP)
    }

    /// Known limit: WebKit strips Set-Cookie from the response it hands the app, so a PHPSESSID
    /// cookie isn't a signal here (it could only ever say "PHP, version hidden", which iSmith
    /// doesn't show). If WebKit starts passing it, this fails and the signal comes back for free.
    func testSessionCookieIsNotVisible() async throws {
        let tab = try await wired.open(server.url("/session.html"))
        XCTAssertEqual(tab.phpCheck?.verdict.level, .noPHP)
    }

    func testSameOriginFrameAddsItsEvidence() async throws {
        let tab = try await wired.open(server.url("/framed.html"))
        let merged = await eventually(timeout: 10) { tab.phpCheck?.verdict.level == .vulnerable }
        XCTAssertTrue(merged, "the frame's PHP/7.4.3 counts for the page")
        XCTAssertEqual(tab.phpCheck?.verdict.version, "7.4.3")
    }

    func testPasswordFocusWarnsOnceOnAnUnpatchedSite() async throws {
        let tab = try await wired.open(server.url("/old.html"))
        try await focus("name", in: tab)
        XCTAssertTrue(tab.prompts.isEmpty, "an ordinary field doesn't warn")
        try await focus("pw", in: tab)
        XCTAssertEqual(tab.prompts.map(\.key), ["php2shell"])
        if let prompt = tab.prompts.first { wired.browser.answer(prompt, .allow, in: tab) }
        try await focus("name", in: tab)
        try await focus("pw", in: tab)
        XCTAssertTrue(tab.prompts.isEmpty, "once per page")

        try await wired.waitForNewPage(tab, path: "/new.html") { tab.webView?.load(URLRequest(url: server.url("/new.html"))) }
        try await focus("pw", in: tab)
        XCTAssertTrue(tab.prompts.isEmpty, "a patched site doesn't warn")
    }

    func testTheSettingTurnsItOff() async throws {
        UserDefaults.standard.set(false, forKey: PHPCheck.enabledKey)
        defer { UserDefaults.standard.removeObject(forKey: PHPCheck.enabledKey) }
        let tab = try await wired.open(server.url("/old.html"))
        XCTAssertNil(tab.phpCheck)
        try await focus("pw", in: tab)
        XCTAssertTrue(tab.prompts.isEmpty)
    }
}
