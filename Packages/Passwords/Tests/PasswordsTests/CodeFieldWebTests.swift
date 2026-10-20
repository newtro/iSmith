@testable import Passwords
import WebKit
import XCTest

/// One-time-code fields in a real WKWebView: which fields count, filling a plain and a split
/// field the way a React-like controlled input accepts, refusals, and the frame a field is in.
@MainActor
final class CodeFieldWebTests: XCTestCase {
    private var server: FixtureServer!
    private var h: AutofillHarness!

    override func setUp() async throws {
        server = try FixtureServer()
        try await server.start()
        h = AutofillHarness()
    }

    override func tearDown() async throws {
        h?.tearDown()
        h = nil
        server?.stop()
    }

    private func q(_ s: String) -> String { AutofillHarness.quote(s) }

    private func value(_ id: String, in frame: WKFrameInfo? = nil) async throws -> String {
        try await h.pageString("return document.getElementById(\(q(id))).value", in: frame)
    }

    /// Focuses a field from page script (as pages do with their code field) and waits for a code
    /// focus.
    private func codeFocus(_ id: String, in frame: WKFrameInfo? = nil) async throws -> CodeFieldFocus {
        let before = h.codeFocuses.count
        try await h.page("document.getElementById(\(q(id))).focus()", in: frame)
        try await h.waitUntil("a code focus for #\(id)") { h.codeFocuses.count > before }
        return h.codeFocuses.last!
    }

    /// Focuses each field and checks that none is taken for a code field.
    private func assertNotCodeFields(_ ids: [String], file: StaticString = #filePath, line: UInt = #line) async throws {
        for id in ids {
            let before = h.codeFocuses.count
            try await h.page("document.getElementById(\(q(id))).focus()")
            try await h.settle(0.25)
            XCTAssertEqual(h.codeFocuses.count, before, "#\(id) was taken for a code field", file: file, line: line)
        }
    }

    // MARK: Detection

    func testPlainOneTimeCodeFieldFillsLikeTyping() async throws {
        try await h.load(server.url("/code-plain.html"))
        try await h.settle(0.3)
        // Nothing is reported or filled on load.
        XCTAssertTrue(h.codeFocuses.isEmpty)

        try await h.click("otp")
        let focus = try XCTUnwrap(h.codeFocuses.last)
        XCTAssertTrue(focus.isUserInitiated)
        XCTAssertEqual(focus.boxes, 1)
        XCTAssertEqual(focus.maxLength, 6)
        XCTAssertTrue(focus.frame.isMainFrame)
        XCTAssertEqual(focus.pageHost, "127.0.0.1", "loopback http counts as a page codes may go to")
        XCTAssertNotNil(focus.rectInWebView)
        XCTAssertEqual(h.autofill.lastCodeFocus(in: h.webView)?.fieldID, focus.fieldID)
        XCTAssertTrue(h.focuses.isEmpty, "a code field is not a login field")

        // Codes that don't fit are refused before anything reaches the page.
        for bad in ["1234567", "12 34", "12", "１２３４５６", "<b>1</b>"] {
            do {
                try await h.autofill.fillCode(bad, into: focus)
                XCTFail("filled \(bad)")
            } catch {
                XCTAssertEqual(error as? AutofillError, .codeDoesNotFit, bad)
            }
        }
        let untouched = try await value("otp")
        XCTAssertEqual(untouched, "")

        // The fixture is strict: a value set without an input event the page sees is reverted.
        try await h.page("Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(document.getElementById('otp'), '999999')")
        var reverted = "999999"
        for _ in 0..<40 where reverted != "" {
            try await h.settle(0.05)
            reverted = try await value("otp")
        }
        XCTAssertEqual(reverted, "", "the controlled input put its state back")

        try await h.autofill.fillCode("482913", into: focus)
        try await h.settle(0.2) // past a few of the page's re-renders
        let filled = try await value("otp")
        XCTAssertEqual(filled, "482913")
        let state = try await h.pageString("return window.state.otp")
        XCTAssertEqual(state, "482913", "the controlled input's state took the code")
        let events = try await h.pageString("return window.events.join(' ')")
        XCTAssertEqual(events, "otp:keydown otp:input:insertText:482913 otp:keyup otp:change")
    }

    func testSplitBoxesAreOneFieldAndEachBoxIsTyped() async throws {
        try await h.load(server.url("/code-split.html"))
        try await h.settle(0.3)
        try await h.click("b2")
        let focus = try XCTUnwrap(h.codeFocuses.last)
        XCTAssertEqual(focus.boxes, 6)
        XCTAssertEqual(focus.maxLength, 6)
        XCTAssertTrue(focus.isUserInitiated)
        // Moving to another box is the same field, named by its first box.
        try await h.settle(0.5)
        let other = try await codeFocus("b0")
        XCTAssertEqual(other.fieldID, focus.fieldID)
        XCTAssertTrue(other.isUserInitiated, "the page moving focus along the boxes keeps it the user's field")
        XCTAssertTrue(h.codeBlurs.isEmpty, "moving between the boxes isn't leaving the field")

        do {
            try await h.autofill.fillCode("12345", into: focus)
            XCTFail("filled 5 digits into 6 boxes")
        } catch {
            XCTAssertEqual(error as? AutofillError, .codeDoesNotFit)
        }

        let before = h.codeFocuses.count
        try await h.autofill.fillCode("905172", into: focus)
        try await h.settle(0.2)
        var boxes: [String] = []
        for i in 0..<6 { boxes.append(try await value("b\(i)")) }
        XCTAssertEqual(boxes, ["9", "0", "5", "1", "7", "2"])
        let state = try await h.pageString("return window.state.code")
        XCTAssertEqual(state, "905172", "every box took its digit, with the page's state re-rendered in between")
        XCTAssertEqual(h.codeFocuses.count, before, "typing along the boxes reports no new focus")

        // Two single-character boxes are not a code field.
        try await assertNotCodeFields(["m0", "m1"])
    }

    func testHeuristicCodeFieldsAreFound() async throws {
        try await h.load(server.url("/code-heuristic.html"))
        try await h.settle(0.3)
        for id in ["named", "labelled", "numeric", "mfa", "spanish", "german", "japanese", "clear"] {
            let focus = try await codeFocus(id)
            XCTAssertEqual(focus.boxes, 1, id)
        }
        let numeric = try await codeFocus("numeric")
        XCTAssertEqual(numeric.maxLength, 6)
        try await h.autofill.fillCode("1234", into: numeric)
        let filled = try await value("numeric")
        XCTAssertEqual(filled, "1234")
        // A transparent input over drawn boxes still takes the code.
        let clear = try await codeFocus("clear")
        try await h.autofill.fillCode("246810", into: clear)
        let clearValue = try await value("clear")
        XCTAssertEqual(clearValue, "246810")
    }

    func testZipQuantityCardSearchAndPasswordFieldsAreNotCodeFields() async throws {
        try await h.load(server.url("/code-negative.html"))
        try await h.settle(0.3)
        try await assertNotCodeFields(["zip", "zip2", "qty", "promo", "pw", "year", "search", "phone", "customer", "ccnum", "ccexp", "csc", "cccode"])
    }

    // MARK: Refusals

    func testFocusLeavingTheFieldIsReportedAndFillAfterNavigationIsRefused() async throws {
        try await h.load(server.url("/code-plain.html"))
        let focus = try await codeFocus("otp")
        XCTAssertFalse(focus.isUserInitiated, "a page focusing its code field isn't the user")

        try await h.page("document.getElementById('other').focus()")
        try await h.waitUntil("a code blur") { !h.codeBlurs.isEmpty }
        XCTAssertEqual(h.codeBlurs, [focus.fieldID])
        XCTAssertNil(h.autofill.lastCodeFocus(in: h.webView))

        try await h.load(server.url("/code-plain.html"))
        do {
            try await h.autofill.fillCode("123456", into: focus)
            XCTFail("filled a page that was replaced")
        } catch {
            XCTAssertEqual(error as? AutofillError, .stale)
        }
        let after = try await value("otp")
        XCTAssertEqual(after, "")
    }

    func testDisabledWebViewGetsNoCodeFocusAndNoFill() async throws {
        try await h.load(server.url("/code-plain.html"))
        let focus = try await codeFocus("otp")
        h.autofill.setDisabled(true, for: h.webView)
        XCTAssertNil(h.autofill.lastCodeFocus(in: h.webView))
        do {
            try await h.autofill.fillCode("123456", into: focus)
            XCTFail("filled a disabled web view")
        } catch {
            XCTAssertEqual(error as? AutofillError, .disabled)
        }
        let before = h.codeFocuses.count
        try await h.page("document.getElementById('other').focus(); document.getElementById('otp').focus()")
        try await h.settle(0.5)
        XCTAssertEqual(h.codeFocuses.count, before)
    }

    func testFillRightAfterTheFocusIsRefused() async throws {
        h.autofill.minimumFocusAge = 5
        try await h.load(server.url("/code-plain.html"))
        let focus = try await codeFocus("otp")
        do {
            try await h.autofill.fillCode("123456", into: focus)
            XCTFail("filled too soon")
        } catch {
            XCTAssertEqual(error as? AutofillError, .tooSoon)
        }
    }

    // MARK: Frames

    func testIframeCodeFieldIsLookedUpForTheTopLevelHost() async throws {
        // Loads the page and collects its frames' WKFrameInfo.
        let frames = try await loadCollectingFrames("/code-frame-host.html")
        let top = try await codeFocus("top")
        XCTAssertTrue(top.frame.isMainFrame)
        XCTAssertEqual(top.pageHost, "127.0.0.1")

        let iframe = try XCTUnwrap(frames.first { !$0.isMainFrame && $0.securityOrigin.host == "localhost" })
        let framed = try await codeFocus("framed", in: iframe)
        XCTAssertFalse(framed.frame.isMainFrame)
        XCTAssertEqual(framed.frame.origin.host, "localhost")
        XCTAssertEqual(framed.pageHost, "127.0.0.1", "the tab's top-level host, never the frame's")
        XCTAssertNil(framed.rectInWebView)

        // Unbound codes follow the top-level page; a bound code needs both hosts.
        XCTAssertTrue(OneTimeCodeBinding.mayOffer(domain: nil, in: framed))
        XCTAssertFalse(OneTimeCodeBinding.mayOffer(domain: "localhost", in: framed), "the frame's site, but not the page's")
        XCTAssertFalse(OneTimeCodeBinding.mayOffer(domain: "127.0.0.1", in: framed), "the page's site, but not the frame's")
        XCTAssertTrue(OneTimeCodeBinding.mayOffer(domain: "127.0.0.1", in: top))

        try await h.autofill.fillCode("246810", into: framed)
        let inFrame = try await value("framed", in: iframe)
        XCTAssertEqual(inFrame, "246810")
        let inTop = try await value("top")
        XCTAssertEqual(inTop, "", "nothing went into the top page")
    }

    /// Loads a page with a script in another content world that reports from every frame, and
    /// returns each frame's WKFrameInfo (for running script in a cross-origin iframe).
    private func loadCollectingFrames(_ path: String) async throws -> [WKFrameInfo] {
        let collector = FrameCollector()
        let controller = h.webView.configuration.userContentController
        controller.add(collector, contentWorld: .defaultClient, name: "frameCollector")
        controller.addUserScript(WKUserScript(source: "window.webkit.messageHandlers.frameCollector.postMessage(1)",
                                              injectionTime: .atDocumentEnd, forMainFrameOnly: false, in: .defaultClient))
        try await h.load(server.url(path))
        try await h.waitUntil("both frames") { collector.frames.count >= 2 }
        try await h.settle(0.3)
        return collector.frames
    }
}

private final class FrameCollector: NSObject, WKScriptMessageHandler {
    var frames: [WKFrameInfo] = []
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        frames.append(message.frameInfo)
    }
}

/// The binding decision without WebKit.
final class OneTimeCodeBindingTests: XCTestCase {
    func testHostMatchesDomainOrSubdomainOnly() {
        XCTAssertTrue(OneTimeCodeBinding.hostMatches("chase.com", domain: "chase.com"))
        XCTAssertTrue(OneTimeCodeBinding.hostMatches("secure.login.chase.com", domain: "chase.com"))
        XCTAssertTrue(OneTimeCodeBinding.hostMatches("Chase.COM.", domain: "chase.com"))
        XCTAssertFalse(OneTimeCodeBinding.hostMatches("evilchase.com", domain: "chase.com"))
        XCTAssertFalse(OneTimeCodeBinding.hostMatches("chase.com.evil.example", domain: "chase.com"))
        XCTAssertFalse(OneTimeCodeBinding.hostMatches("chase.com", domain: "login.chase.com"), "a parent isn't a subdomain")
        XCTAssertFalse(OneTimeCodeBinding.hostMatches("", domain: "chase.com"))
        XCTAssertFalse(OneTimeCodeBinding.hostMatches("chase.com", domain: ""))
    }

    func testMainFrameUsesTheTopLevelHost() {
        XCTAssertTrue(OneTimeCodeBinding.mayOffer(domain: "chase.com", topHost: "www.chase.com", frameHost: "www.chase.com", isMainFrame: true))
        XCTAssertFalse(OneTimeCodeBinding.mayOffer(domain: "chase.com", topHost: "evil.example", frameHost: "evil.example", isMainFrame: true))
        XCTAssertTrue(OneTimeCodeBinding.mayOffer(domain: nil, topHost: "evil.example", frameHost: "evil.example", isMainFrame: true),
                      "unbound codes: the agent's 2-minute rule decides")
    }

    func testIframeNeedsBothHostsForABoundCode() {
        // chase.com framing its own login widget.
        XCTAssertTrue(OneTimeCodeBinding.mayOffer(domain: "chase.com", topHost: "www.chase.com", frameHost: "auth.chase.com", isMainFrame: false))
        // An evil page framing chase.com: the frame matches, the page doesn't.
        XCTAssertFalse(OneTimeCodeBinding.mayOffer(domain: "chase.com", topHost: "evil.example", frameHost: "auth.chase.com", isMainFrame: false))
        // chase.com framing a third party: the page matches, the frame doesn't.
        XCTAssertFalse(OneTimeCodeBinding.mayOffer(domain: "chase.com", topHost: "www.chase.com", frameHost: "widget.vendor.example", isMainFrame: false))
        // Unbound codes follow the top-level page alone.
        XCTAssertTrue(OneTimeCodeBinding.mayOffer(domain: nil, topHost: "www.chase.com", frameHost: "widget.vendor.example", isMainFrame: false))
    }

    func testCodesOnlyOnHTTPSOrLoopback() {
        XCTAssertEqual(OneTimeCodeBinding.pageHost(top: Origin(string: "https://Login.Chase.com")), "login.chase.com")
        XCTAssertEqual(OneTimeCodeBinding.pageHost(top: Origin(string: "http://127.0.0.1:8080")), "127.0.0.1")
        XCTAssertEqual(OneTimeCodeBinding.pageHost(top: Origin(string: "http://localhost:3000")), "localhost")
        XCTAssertNil(OneTimeCodeBinding.pageHost(top: Origin(string: "http://chase.com")), "plain http: anyone on the network could be the page")
        XCTAssertNil(OneTimeCodeBinding.pageHost(top: nil), "opaque origins get nothing")
    }

    func testPlausibleCodes() {
        XCTAssertTrue(OneTimeCodeBinding.isPlausibleCode("123456"))
        XCTAssertTrue(OneTimeCodeBinding.isPlausibleCode("G-12345".replacingOccurrences(of: "-", with: "")))
        XCTAssertFalse(OneTimeCodeBinding.isPlausibleCode("12"))
        XCTAssertFalse(OneTimeCodeBinding.isPlausibleCode("1234567890123"))
        XCTAssertFalse(OneTimeCodeBinding.isPlausibleCode("12 34"))
        XCTAssertFalse(OneTimeCodeBinding.isPlausibleCode("１２３４５６"), "full-width digits")
    }
}
