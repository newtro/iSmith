import CodesXPC
import Passwords
import WebKit
import XCTest
@testable import iSmith

/// Codes in one-time-code fields: the popover offers what the code source has for the page's
/// top-level host (rechecked against the binding), fills only on a pick or ⌘\, picks up a code
/// that arrives while the field is focused, and leaves agent tabs and an absent agent alone.
/// Input is real (trusted) mouse events in an offscreen window; the agent is a stand-in.
@MainActor
final class CodeFillWiringTests: XCTestCase {
    private var server: TestHTTPServer!
    private var wired: WiredBrowser!
    private var codes: FakeCodeSource!

    private static let verify = """
        <!doctype html><title>Verify</title><body style="margin:40px">
        <form id="f" onsubmit="event.preventDefault()">
          <input id="otp" autocomplete="one-time-code" inputmode="numeric" maxlength="6" style="display:block;width:240px;height:28px">
          <input id="note" name="note" type="text" style="display:block;width:240px;height:28px;margin-top:10px">
        </form></body>
        """

    private static let mixed = """
        <!doctype html><title>Sign in</title><body style="margin:40px">
        <form id="f" onsubmit="event.preventDefault()">
          <input id="username" type="email" autocomplete="username" style="display:block;width:240px;height:28px">
          <input id="password" type="password" autocomplete="current-password" style="display:block;width:240px;height:28px;margin-top:10px">
        </form>
        <input id="otp" autocomplete="one-time-code" maxlength="6" style="display:block;width:240px;height:28px;margin-top:10px">
        </body>
        """

    override func setUp() async throws {
        server = try TestHTTPServer(routes: ["/verify.html": .html(Self.verify), "/mixed.html": .html(Self.mixed)])
        try await server.start()
        wired = try WiredBrowser()
        codes = FakeCodeSource()
        let fill = wired.browser.passwordUI.codeFill
        fill.source = codes
        fill.pollInterval = 0.2
    }

    override func tearDown() async throws {
        wired?.browser.passwordUI.codeFill.stop()
        await wired?.tearDown()
        server?.stop()
    }

    private var ui: PasswordUI { wired.browser.passwordUI }

    private func openShown(_ path: String = "/verify.html") async throws -> Tab {
        let tab = try await wired.open(server.url(path))
        try wired.show(tab)
        try await Task.sleep(nanoseconds: 400_000_000)
        return tab
    }

    private func offer(_ code: String, sender: String = "Chase", domain: String? = nil, age: TimeInterval = 5) -> CodeOffer {
        CodeOffer(id: UUID().uuidString, code: code, sender: sender, domain: domain, receivedAt: Date().addingTimeInterval(-age))
    }

    func testPopoverOffersTheCodeAndFillsOnlyOnAPick() async throws {
        let code = offer("482913")
        codes.offers = [code]
        let tab = try await openShown()
        XCTAssertNil(ui.codeModel, "nothing on load")

        try await wired.click("otp", in: tab)
        let shown = await eventually { self.ui.codeModel != nil }
        XCTAssertTrue(shown, "the popover opened for the code field")
        XCTAssertEqual(ui.codeModel?.offers.map(\.id), [code.id])
        XCTAssertEqual(ui.codeModel?.highlighted, 0, "a click preselects the code")
        XCTAssertNil(ui.codeModel?.crossSiteHost)
        XCTAssertEqual(codes.hosts.first, "127.0.0.1", "asked for the page's top-level host")
        let before = try await wired.value("otp", in: tab)
        XCTAssertEqual(before, "", "showing a code fills nothing")

        // A pick in the first half second is ignored.
        ui.codeModel?.choose(0)
        try await Task.sleep(nanoseconds: 200_000_000)
        let early = try await wired.value("otp", in: tab)
        XCTAssertEqual(early, "")

        try await Task.sleep(nanoseconds: 400_000_000)
        ui.codeModel?.choose(0)
        let filled = await eventually { (try? await self.wired.value("otp", in: tab)) == "482913" }
        XCTAssertTrue(filled)
        XCTAssertNil(ui.codeModel, "the popover closed")
        let used = await eventually { self.codes.used == [code.id] }
        XCTAssertTrue(used, "the code was marked used")
        XCTAssertFalse(ui.codeFill.isWatching, "filling ends the watch")
    }

    func testOnlyCodesTheBindingAllowsAndThatFitAreOffered() async throws {
        // A source that returns too much (an older agent, say): the app checks again.
        let mine = offer("111222", domain: "127.0.0.1")
        let other = offer("333444", domain: "chase.com")
        let tooLong = offer("12345678")
        let older = offer("555666", age: 30)
        codes.offers = [older, mine, other, tooLong]
        let tab = try await openShown()
        try await wired.click("otp", in: tab)
        let shown = await eventually { self.ui.codeModel != nil }
        XCTAssertTrue(shown)
        XCTAssertEqual(ui.codeModel?.offers.map(\.code), ["111222", "555666"], "bound to this host or unbound, newest first")
        XCTAssertEqual(CodePopoverModel.source(of: mine).domain, "127.0.0.1")
    }

    func testACodeArrivingWhileTheFieldIsFocusedShowsThePopover() async throws {
        let tab = try await openShown()
        // The page focuses its own code field, as verification pages do.
        _ = try await tab.webView?.evaluateJavaScript("document.getElementById('otp').focus(); 1")
        let watching = await eventually { self.ui.codeFill.isWatching }
        XCTAssertTrue(watching)
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(ui.codeModel, "no code yet")
        XCTAssertGreaterThan(codes.calls, 1, "it keeps asking while the field is focused")

        // An unbound code isn't put up for a field only the page focused...
        let unbound = offer("770011", age: 0)
        codes.offers = [unbound]
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNil(ui.codeModel, "no unbound code without the user's click")
        // ...a code bound to this site is.
        let bound = offer("880022", domain: "127.0.0.1", age: 0)
        codes.offers = [unbound, bound]
        let shown = await eventually(timeout: 3) { self.ui.codeModel != nil }
        XCTAssertTrue(shown, "the new bound code was offered")
        XCTAssertEqual(ui.codeModel?.offers.map(\.id), [bound.id])
        XCTAssertNil(ui.codeModel?.highlighted, "not preselected when it opens by itself")
        XCTAssertEqual(ui.codeModel?.inputDelay, CodePopoverModel.unexpectedInputDelay)
        let value = try await wired.value("otp", in: tab)
        XCTAssertEqual(value, "", "and not filled")

        // Escape, then the same code isn't offered again unasked...
        ui.close()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(ui.codeModel)
        // ...but the user's click asks again, now with the unbound code too.
        try await wired.click("otp", in: tab)
        let again = await eventually(timeout: 3) { self.ui.codeModel != nil }
        XCTAssertTrue(again)
        XCTAssertEqual(Set(ui.codeModel?.offers.map(\.id) ?? []), [bound.id, unbound.id])
        XCTAssertEqual(ui.codeModel?.highlighted, 0, "preselected after a click")
        ui.close()

        // Focus leaving the field ends the watch.
        try await wired.click("note", in: tab)
        let stopped = await eventually { !self.ui.codeFill.isWatching }
        XCTAssertTrue(stopped)
        let calls = codes.calls
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertEqual(codes.calls, calls, "no more asking")
    }

    /// The user clicks a password field, then the page moves focus to a code field: ⌘\ still
    /// fills the login, and no code goes anywhere.
    func testCommandBackslashAfterAPageFocusedCodeFieldFillsTheLogin() async throws {
        let store = try XCTUnwrap(wired.browser.passwords?.store)
        try store.add(origin: Origin(url: server.url("/"))!, username: "scott@example.com", password: "Saved-Secret-1")
        codes.offers = [offer("482913")]
        let tab = try await openShown("/mixed.html")
        try await wired.click("password", in: tab)
        ui.close()
        _ = try await tab.webView?.evaluateJavaScript("document.getElementById('otp').focus(); 1")
        try await Task.sleep(nanoseconds: 400_000_000)
        ui.fillShortcut(in: tab.webView)
        let filled = await eventually { (try? await self.wired.value("password", in: tab)) == "Saved-Secret-1" }
        XCTAssertTrue(filled, "⌘\\ filled the login")
        let code = try await wired.value("otp", in: tab)
        XCTAssertEqual(code, "", "the code went nowhere")
        XCTAssertTrue(codes.used.isEmpty)
    }

    func testCommandBackslashFillsTheNewestCode() async throws {
        codes.offers = [offer("100200", age: 60), offer("300400", age: 2)]
        let tab = try await openShown()
        try await wired.click("otp", in: tab)
        _ = await eventually { self.ui.codeModel != nil }
        ui.close()
        try await Task.sleep(nanoseconds: 350_000_000)
        ui.fillShortcut(in: tab.webView)
        let filled = await eventually { (try? await self.wired.value("otp", in: tab)) == "300400" }
        XCTAssertTrue(filled, "⌘\\ filled the newest code")
    }

    func testNoAgentMeansNoQuestionsAndNoPopover() async throws {
        codes.available = false
        codes.offers = [offer("482913")]
        let tab = try await openShown()
        try await wired.click("otp", in: tab)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(ui.codeModel)
        XCTAssertEqual(codes.calls, 0, "the agent isn't asked when codes are off")
        XCTAssertFalse(ui.codeFill.isWatching)
    }

    func testAgentTabsGetNoCodes() async throws {
        codes.offers = [offer("482913")]
        let tab = try await openShown()
        wired.browser.setAgentControlled(true, for: tab)
        try await wired.click("otp", in: tab)
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertNil(ui.codeModel, "no popover")
        ui.fillShortcut(in: tab.webView)
        try await Task.sleep(nanoseconds: 400_000_000)
        let value = try await wired.value("otp", in: tab)
        XCTAssertEqual(value, "", "nothing filled")
        XCTAssertEqual(codes.calls, 0)
    }
}

@MainActor
private final class FakeCodeSource: CodeSource {
    var available = true
    var offers: [CodeOffer] = []
    private(set) var hosts: [String] = []
    private(set) var used: [String] = []
    var calls: Int { hosts.count }

    var isAvailable: Bool { available }

    func offers(forPageHost host: String) async -> [CodeOffer] {
        hosts.append(host)
        return offers.filter { !used.contains($0.id) }
    }

    func markUsed(_ id: String) async { used.append(id) }
}
