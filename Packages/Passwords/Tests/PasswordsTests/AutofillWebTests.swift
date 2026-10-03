@testable import Passwords
import WebKit
import XCTest

/// Capture and fill in a real WKWebView, on the local HTML fixtures served over HTTP.
@MainActor
final class AutofillWebTests: XCTestCase {
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

    private var origin: Origin { Origin(url: server.url("/"))! }
    private var localhostOrigin: Origin { Origin(url: server.url("/", host: "localhost"))! }

    private func value(_ id: String, in frame: WKFrameInfo? = nil) async throws -> String {
        try await h.pageString("return document.getElementById(\(jsonQuote(id))).value", in: frame)
    }

    private func jsonQuote(_ s: String) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: [s]).dropFirst().dropLast(), as: UTF8.self)
    }

    private func focus(_ id: String, in frame: WKFrameInfo? = nil) async throws -> LoginFieldFocus {
        let before = h.focuses.count
        try await h.page("document.getElementById(\(jsonQuote(id))).focus()", in: frame)
        try await h.waitUntil("a focus event for #\(id)") { h.focuses.count > before }
        return h.focuses.last!
    }

    private func type(_ id: String, _ text: String, in frame: WKFrameInfo? = nil) async throws {
        try await h.page("document.getElementById(\(jsonQuote(id))).value = \(jsonQuote(text))", in: frame)
    }

    // MARK: Single-page login

    func testSinglePageLoginFillsOnlyWhenAskedAndCapturesSubmissions() async throws {
        let saved = try h.store.add(origin: origin, username: "scott@example.com", password: "Saved-Secret-1")
        try h.store.add(origin: Origin(string: "https://other.example")!, username: "nope", password: "nope")
        try await h.load(server.url("/login.html"))
        try await h.waitUntil("the login form to be found") { h.forms.contains { $0.kinds.contains(.login) } }

        // Nothing is filled on load, even with a saved login.
        try await h.settle(0.5)
        let emptyUser = try await value("username"), emptyPass = try await value("password")
        XCTAssertEqual(emptyUser, "")
        XCTAssertEqual(emptyPass, "")
        XCTAssertTrue(h.focuses.isEmpty)

        let focus = try await focus("username")
        XCTAssertEqual(focus.field, .username)
        XCTAssertEqual(focus.form, .login)
        XCTAssertEqual(focus.frame.origin, origin)
        XCTAssertTrue(focus.frame.isMainFrame)
        XCTAssertFalse(focus.frame.isCrossSite)
        XCTAssertEqual(focus.logins.map(\.id), [saved.id], "only this origin's logins")
        XCTAssertEqual(focus.logins.first?.matchKind, .exact)
        XCTAssertNotNil(focus.rectInWebView)
        XCTAssertGreaterThan(focus.rect.width, 0)
        XCTAssertFalse(focus.offersGeneratedPassword)
        XCTAssertEqual(h.autofill.lastFocus(in: h.webView)?.fieldID, focus.fieldID)

        // The search box is not a login field.
        let count = h.focuses.count
        try await h.page("document.getElementById('search').focus()")
        try await h.settle(0.4)
        XCTAssertEqual(h.focuses.count, count)

        try await h.autofill.fill(saved.id, into: focus)
        let filledUser = try await value("username"), filledPass = try await value("password")
        XCTAssertEqual(filledUser, "scott@example.com")
        XCTAssertEqual(filledPass, "Saved-Secret-1")
        let events = try await h.pageString("return JSON.stringify(window.inputEvents)")
        XCTAssertEqual(events, #"{"username":1,"password":1}"#, "the page saw input events, as for typing")
        XCTAssertNotNil(try h.store.login(id: saved.id)?.lastUsed, "filling marks the login used")

        // Signing in with the filled login: already saved, so nothing to ask.
        try await h.page("document.getElementById('login').requestSubmit()")
        try await h.settle()
        XCTAssertTrue(h.captures.isEmpty)

        // A new account: offered for saving.
        try await type("username", "new.user")
        try await type("password", "New-Password-2")
        try await h.page("document.getElementById('login').requestSubmit()")
        try await h.waitUntil("a capture") { !h.captures.isEmpty }
        let capture = h.captures[0]
        XCTAssertEqual(capture.origin, origin)
        XCTAssertEqual(capture.username, "new.user")
        XCTAssertEqual(capture.password, "New-Password-2")
        XCTAssertEqual(capture.action, .save)
        XCTAssertEqual(capture.form, .login)
        XCTAssertFalse(String(describing: capture).contains("New-Password"), "captures don't print their password")
        let created = try h.autofill.save(capture)
        XCTAssertEqual(try h.store.login(id: created.id)?.password, "New-Password-2")

        // The same account with a new password: offered as an update.
        try await type("password", "Changed-Password-3")
        try await h.page("document.getElementById('signin').click()") // an untrusted click is ignored...
        try await h.page("document.getElementById('login').requestSubmit()") // ...the submit is seen
        try await h.waitUntil("an update capture") { h.captures.count == 2 }
        XCTAssertEqual(h.captures[1].action, .update(existing: created.id))
        XCTAssertEqual(h.captures[1].password, "Changed-Password-3")

        // "Never for this site" silences it.
        try h.autofill.neverSave(h.captures[1])
        try await type("password", "Changed-Again-4")
        try await h.page("document.getElementById('login').requestSubmit()")
        try await h.settle()
        XCTAssertEqual(h.captures.count, 2)
    }

    // MARK: Two-step sign-in

    func testTwoStepSignInRemembersTheUsernameAcrossPages() async throws {
        try await h.load(server.url("/step1.html"))
        let step1 = try await focus("email")
        XCTAssertEqual(step1.form, .usernameOnly)
        XCTAssertEqual(step1.field, .username)

        try await type("email", "two.step@example.com")
        try await h.waitForNavigation {
            try await h.page("document.getElementById('step1').requestSubmit()")
        }
        XCTAssertTrue(h.webView.url?.path.hasSuffix("step2.html") == true)
        XCTAssertTrue(h.captures.isEmpty, "the username step alone isn't offered for saving")

        let step2 = try await focus("password")
        XCTAssertEqual(step2.form, .login)
        XCTAssertEqual(step2.field, .password)
        try await type("password", "Two-Step-Secret-5")
        try await h.page("document.getElementById('step2').requestSubmit()")
        try await h.waitUntil("a capture") { !h.captures.isEmpty }
        XCTAssertEqual(h.captures[0].username, "two.step@example.com", "the username from the first page")
        XCTAssertEqual(h.captures[0].password, "Two-Step-Secret-5")
        let saved = try h.autofill.save(h.captures[0])

        // Filling both steps: the username on page one, the password on page two, with the
        // chosen login suggested there.
        h.clearEvents()
        try await h.load(server.url("/step1.html"))
        let fillStep1 = try await focus("email")
        XCTAssertEqual(fillStep1.logins.map(\.id), [saved.id])
        try await h.autofill.fill(saved.id, into: fillStep1)
        let filledEmail = try await value("email")
        XCTAssertEqual(filledEmail, "two.step@example.com")
        try await h.waitForNavigation {
            try await h.page("document.getElementById('step1').requestSubmit()")
        }
        let fillStep2 = try await focus("password")
        XCTAssertEqual(fillStep2.suggestedLoginID, saved.id)
        let notYet = try await value("password")
        XCTAssertEqual(notYet, "", "the second step isn't filled until asked")
        try await h.autofill.fill(saved.id, into: fillStep2)
        let filled = try await value("password")
        XCTAssertEqual(filled, "Two-Step-Secret-5")
    }

    // MARK: Signup

    func testSignupFormOffersAndFillsAGeneratedPassword() async throws {
        try await h.load(server.url("/signup.html"))
        try await h.waitUntil("the signup form to be found") { h.forms.contains { $0.kinds.contains(.signup) } }
        let focus = try await focus("new")
        XCTAssertEqual(focus.form, .signup)
        XCTAssertEqual(focus.field, .newPassword)
        XCTAssertTrue(focus.offersGeneratedPassword)
        XCTAssertEqual(focus.requirements.maxLength, 24)
        XCTAssertEqual(focus.requirements.rules, "required: upper; required: digit; minlength: 12; maxlength: 24;")

        let generated = PasswordGenerator.generate(focus.requirements)
        XCTAssertTrue((12...24).contains(generated.count))
        try await h.autofill.fillGeneratedPassword(generated, into: focus)
        let newValue = try await value("new"), confirmValue = try await value("confirm")
        XCTAssertEqual(newValue, generated)
        XCTAssertEqual(confirmValue, generated)

        try await type("email", "signup@example.com")
        try await h.page("document.getElementById('signup').requestSubmit()")
        try await h.waitUntil("a capture") { !h.captures.isEmpty }
        XCTAssertEqual(h.captures[0].form, .signup)
        XCTAssertEqual(h.captures[0].username, "signup@example.com")
        XCTAssertEqual(h.captures[0].password, generated)
        XCTAssertEqual(h.captures[0].action, .save)

        // Mismatched confirmation: not a password worth saving.
        h.clearEvents()
        try await type("new", "Mismatch-One-1")
        try await type("confirm", "Mismatch-Two-2")
        try await h.page("document.getElementById('signup').requestSubmit()")
        try await h.settle()
        XCTAssertTrue(h.captures.isEmpty)
    }

    // MARK: Frames

    func testCrossOriginIframeGetsOnlyItsOwnLogins() async throws {
        let top = try h.store.add(origin: origin, username: "top-user", password: "Top-Secret-6")
        let framed = try h.store.add(origin: localhostOrigin, username: "frame-user", password: "Frame-Secret-7")
        try await h.load(server.url("/frame-host.html"))
        try await h.waitUntil("the iframe's login form to be found") {
            h.forms.contains { !$0.frame.isMainFrame && $0.frame.origin == localhostOrigin }
        }
        try await h.settle(0.5)
        // The sandboxed frame has an opaque origin: it's ignored entirely.
        for found in h.forms {
            XCTAssertTrue([origin, localhostOrigin].contains(found.frame.origin), "unexpected frame origin \(found.frame.origin)")
        }
        XCTAssertEqual(h.forms.filter { !$0.frame.isMainFrame }.count, 1, "only the cross-origin frame, not the sandboxed one")
        let iframe = h.forms.first { !$0.frame.isMainFrame }!.frame

        let frameFocus = try await focus("username", in: iframe.frameInfo)
        XCTAssertFalse(frameFocus.frame.isMainFrame)
        XCTAssertEqual(frameFocus.frame.origin, localhostOrigin, "matched against the frame's own origin")
        XCTAssertEqual(frameFocus.frame.topOrigin, origin)
        XCTAssertTrue(frameFocus.frame.isCrossSite)
        XCTAssertNil(frameFocus.rectInWebView)
        XCTAssertEqual(frameFocus.logins.map(\.id), [framed.id], "the top page's login is not offered in the frame")

        // Even if the app asked, the top page's login is refused for the frame.
        do {
            try await h.autofill.fill(top.id, into: frameFocus)
            XCTFail("filled another origin's login into the frame")
        } catch {
            XCTAssertEqual(error as? AutofillError, .originMismatch)
        }
        let leakedUser = try await value("username", in: iframe.frameInfo)
        let leakedPass = try await value("password", in: iframe.frameInfo)
        XCTAssertEqual(leakedUser, "")
        XCTAssertEqual(leakedPass, "")

        // Its own login fills the frame and nothing in the top page.
        try await h.autofill.fill(framed.id, into: frameFocus)
        let frameUser = try await value("username", in: iframe.frameInfo)
        let framePass = try await value("password", in: iframe.frameInfo)
        XCTAssertEqual(frameUser, "frame-user")
        XCTAssertEqual(framePass, "Frame-Secret-7")
        let topPass = try await value("password")
        XCTAssertEqual(topPass, "")

        // And the top page gets only its own.
        let topFocus = try await focus("username")
        XCTAssertEqual(topFocus.logins.map(\.id), [top.id])
        do {
            try await h.autofill.fill(framed.id, into: topFocus)
            XCTFail("filled the frame's login into the top page")
        } catch {
            XCTAssertEqual(error as? AutofillError, .originMismatch)
        }
    }

    // MARK: Page scripts

    func testPageScriptsCannotReachTheContentWorld() async throws {
        try h.store.add(origin: origin, username: "victim", password: "Victim-Secret-8")
        // A page-world handler of the app's own, so `window.webkit` exists in the page.
        h.webView.configuration.userContentController.add(NoopHandler(), contentWorld: .page, name: "pageHandler")
        try await h.load(server.url("/probe.html"))
        try await h.settle()

        let probeValue = try await h.page("return window.probe")
        let probe = try XCTUnwrap(probeValue as? [String: Any])
        XCTAssertEqual(probe["hasWebkit"] as? String, "object", "the page world has window.webkit")
        XCTAssertEqual(probe["handler"] as? String, "undefined", "but not iSmith's handler")
        XCTAssertEqual(probe["fill"] as? String, "undefined", "nor its fill function")
        XCTAssertEqual((probe["globals"] as? [String])?.isEmpty, true, "no iSmith globals in the page world")
        XCTAssertEqual(probe["postError"] as? String, "TypeError", "posting to the handler fails")
        XCTAssertTrue(h.captures.isEmpty, "the fake submission went nowhere")
        XCTAssertTrue(h.focuses.isEmpty, "synthetic focus and mousedown events are ignored")

        // From the content world, the handler and fill function are there.
        let world = try await h.webView.callAsyncJavaScript(
            "return [typeof window.webkit.messageHandlers.ismithPasswords, typeof window.__ismithPasswordsFill].join()",
            arguments: [:], in: nil, contentWorld: h.autofill.contentWorld) as? String
        XCTAssertEqual(world, "object,function")

        // The page's lookalike `__ismithPasswordsFill` isn't what the app calls.
        let focus = try await focus("username")
        try await h.autofill.fill(focus.logins[0].id, into: focus)
        let filled = try await value("password")
        XCTAssertEqual(filled, "Victim-Secret-8")
    }

    func testHiddenFieldsAreNeverOfferedOrFilled() async throws {
        let saved = try h.store.add(origin: origin, username: "user", password: "Hidden-Secret-9")
        try await h.load(server.url("/hidden.html"))
        try await h.settle(0.5)
        for id in ["t-username", "t-password", "o-username", "o-password"] {
            try await h.page("document.getElementById(\(jsonQuote(id))).focus()")
        }
        try await h.settle(0.5)
        XCTAssertTrue(h.focuses.isEmpty, "transparent and off-screen fields get no popover")

        // A visible form that the page hides between the focus and the fill isn't filled.
        let focus = try await focus("password")
        try await h.page("document.getElementById('visible').style.opacity = '0'")
        do {
            try await h.autofill.fill(saved.id, into: focus)
            XCTFail("filled a form that had been hidden")
        } catch {
            XCTAssertEqual(error as? AutofillError, .noField)
        }
        for id in ["username", "password", "t-username", "t-password", "o-username", "o-password"] {
            let v = try await value(id)
            XCTAssertEqual(v, "", "#\(id) stays empty")
        }
    }

    func testFillAfterNavigationIsRefused() async throws {
        let saved = try h.store.add(origin: origin, username: "user", password: "Stale-Secret-10")
        try await h.load(server.url("/login.html"))
        let focus = try await focus("password")
        // The frame loads a new document (same origin, same form ids) before the user picks.
        try await h.load(server.url("/other.html"))
        do {
            try await h.autofill.fill(saved.id, into: focus)
            XCTFail("filled a document other than the focused one")
        } catch {
            XCTAssertEqual(error as? AutofillError, .stale)
        }
        let pass = try await value("password")
        XCTAssertEqual(pass, "")
    }
}

private final class NoopHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
