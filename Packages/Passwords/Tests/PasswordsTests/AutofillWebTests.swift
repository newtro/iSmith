@testable import Passwords
import WebKit
import XCTest

/// Capture and fill in a real WKWebView, on the local HTML fixtures served over HTTP.
///
/// `type` and `click` use real keyboard and mouse input (trusted events), as a user would;
/// `pageSet` and `focus` use page script, as a hostile page would.
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

    private func q(_ s: String) -> String { AutofillHarness.quote(s) }

    private func value(_ id: String, in frame: WKFrameInfo? = nil) async throws -> String {
        try await h.pageString("return document.getElementById(\(q(id))).value", in: frame)
    }

    /// Focuses a field from page script and waits for the focus event.
    private func focus(_ id: String, in frame: WKFrameInfo? = nil) async throws -> LoginFieldFocus {
        let before = h.focuses.count
        try await h.page("document.getElementById(\(q(id))).focus()", in: frame)
        try await h.waitUntil("a focus event for #\(id)") { h.focuses.count > before }
        return h.focuses.last!
    }

    /// Replaces a field's text by typing, as the user would.
    private func type(_ id: String, _ text: String, in frame: WKFrameInfo? = nil) async throws {
        try await h.page("const el = document.getElementById(\(q(id))); el.focus(); el.value = '';", in: frame)
        try await h.typeReal(text)
    }

    /// Sets a field's value from page script (untrusted).
    private func pageSet(_ id: String, _ text: String) async throws {
        try await h.page("document.getElementById(\(q(id))).value = \(q(text))")
    }

    private func submit(_ formID: String, in frame: WKFrameInfo? = nil) async throws {
        try await h.page("document.getElementById(\(q(formID))).requestSubmit()", in: frame)
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

        // A real click: the popover may open, and ⌘\ may fill the exact match.
        try await h.click("username")
        let clicked = try XCTUnwrap(h.focuses.last)
        XCTAssertTrue(clicked.isUserInitiated)
        XCTAssertEqual(clicked.field, .username)
        XCTAssertEqual(clicked.form, .login)
        XCTAssertEqual(clicked.frame.origin, origin)
        XCTAssertTrue(clicked.frame.isMainFrame)
        XCTAssertFalse(clicked.frame.isCrossSite)
        XCTAssertEqual(clicked.logins.map(\.id), [saved.id], "only this origin's logins")
        XCTAssertEqual(clicked.logins.first?.matchKind, .exact)
        XCTAssertNotNil(clicked.rectInWebView)
        XCTAssertGreaterThan(clicked.rect.width, 0)
        XCTAssertFalse(clicked.offersGeneratedPassword)
        XCTAssertEqual(h.autofill.lastFocus(in: h.webView)?.fieldID, clicked.fieldID)
        XCTAssertEqual(h.autofill.bestAutomaticLogin(for: clicked)?.id, saved.id)

        // The search box is not a login field.
        let count = h.focuses.count
        try await h.page("document.getElementById('search').focus()")
        try await h.settle(0.4)
        XCTAssertEqual(h.focuses.count, count)

        try await h.autofill.fill(saved.id, into: clicked)
        let filledUser = try await value("username"), filledPass = try await value("password")
        XCTAssertEqual(filledUser, "scott@example.com")
        XCTAssertEqual(filledPass, "Saved-Secret-1")
        let events = try await h.pageString("return JSON.stringify(window.inputEvents)")
        XCTAssertEqual(events, #"{"username":1,"password":1}"#, "the page saw input events, as for typing")
        XCTAssertNotNil(try h.store.login(id: saved.id)?.lastUsed, "filling marks the login used")

        // Signing in with the filled login: already saved, so nothing to ask.
        try await h.pressReturn()
        try await h.settle()
        XCTAssertTrue(h.captures.isEmpty)

        // A new account, typed: offered for saving.
        try await type("username", "new.user")
        try await type("password", "New-Password-2")
        try await h.pressReturn()
        try await h.waitUntil("a capture") { !h.captures.isEmpty }
        let capture = h.captures[0]
        XCTAssertEqual(capture.origin, origin)
        XCTAssertEqual(capture.username, "new.user")
        XCTAssertEqual(capture.password, "New-Password-2")
        XCTAssertEqual(capture.action, .save)
        XCTAssertEqual(capture.form, .login)
        XCTAssertFalse(String(describing: capture).contains("New-Password"), "captures don't print their password")
        // The user corrected the username in the save bar.
        let created = try h.autofill.save(capture, username: "new.user@example.com")
        XCTAssertEqual(try h.store.login(id: created.id)?.username, "new.user@example.com")
        XCTAssertEqual(try h.store.login(id: created.id)?.password, "New-Password-2")

        // The same account with a new password: offered as an update.
        try await type("username", "new.user@example.com")
        try await type("password", "Changed-Password-3")
        try await h.page("document.getElementById('signin').click()") // an untrusted click is ignored...
        try await h.pressReturn() // ...Return in the field is seen
        try await h.waitUntil("an update capture") { h.captures.count == 2 }
        XCTAssertEqual(h.captures[1].action, .update(existing: created.id))
        XCTAssertEqual(h.captures[1].password, "Changed-Password-3")

        // "Never for this site" silences it.
        try h.autofill.neverSave(h.captures[1])
        try await type("password", "Changed-Again-4")
        try await h.pressReturn()
        try await h.settle()
        XCTAssertEqual(h.captures.count, 2)
    }

    func testScriptFocusIsNotTheUsers() async throws {
        let saved = try h.store.add(origin: origin, username: "user", password: "Script-Focus-1")
        try await h.load(server.url("/login.html"))
        let scripted = try await focus("password")
        XCTAssertFalse(scripted.isUserInitiated, "a page calling focus() is not the user")
        XCTAssertNil(h.autofill.bestAutomaticLogin(for: scripted), "⌘\\ doesn't fill a field the page focused")
        XCTAssertEqual(scripted.logins.map(\.id), [saved.id])

        // Only exact matches are filled automatically, and same-site ones only when picked.
        try await h.click("password")
        let clicked = try XCTUnwrap(h.focuses.last)
        XCTAssertTrue(clicked.isUserInitiated)
        let sibling = LoginSummary(id: UUID(), origin: origin, username: "sibling", lastUsed: nil, matchKind: .sameSite)
        let onlySibling = LoginFieldFocus(
            frame: clicked.frame, fieldID: clicked.fieldID, field: clicked.field, form: clicked.form, rect: clicked.rect,
            rectInWebView: clicked.rectInWebView, logins: [sibling], suggestedLoginID: sibling.id,
            requirements: clicked.requirements, isUserInitiated: true, receivedAt: clicked.receivedAt)
        XCTAssertNil(h.autofill.bestAutomaticLogin(for: onlySibling))
    }

    func testFillRightAfterAFocusIsRefused() async throws {
        let saved = try h.store.add(origin: origin, username: "user", password: "Too-Soon-1")
        h.autofill.minimumFocusAge = 0.3
        try await h.load(server.url("/login.html"))
        let focus = try await focus("password")
        do {
            try await h.autofill.fill(saved.id, into: focus)
            XCTFail("filled within the focus guard")
        } catch {
            XCTAssertEqual(error as? AutofillError, .tooSoon)
        }
        try await h.settle(0.35)
        try await h.autofill.fill(saved.id, into: focus)
        let pass = try await value("password")
        XCTAssertEqual(pass, "Too-Soon-1")
    }

    func testPageCannotForgeSubmissions() async throws {
        try h.store.add(origin: origin, username: "victim", password: "Real-Password-1")
        try await h.load(server.url("/login.html"))
        // Values set by script, then every kind of submit a script can cause.
        try await pageSet("username", "victim")
        try await pageSet("password", "Attacker-Chosen-2")
        try await h.page("document.getElementById('login').dispatchEvent(new Event('submit', { bubbles: true }))")
        try await submit("login")
        try await h.page("document.getElementById('signin').click()")
        try await h.page("""
            const el = document.getElementById('password');
            el.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter', bubbles: true }));
            """)
        try await h.settle()
        XCTAssertTrue(h.captures.isEmpty, "no update offered for values the page made up")
        XCTAssertEqual(try h.store.allLogins().first?.password, "Real-Password-1")
    }

    // MARK: Two-step sign-in

    func testTwoStepSignInRemembersTheUsernameAcrossPages() async throws {
        try await h.load(server.url("/step1.html"))
        let step1 = try await focus("email")
        XCTAssertEqual(step1.form, .usernameOnly)
        XCTAssertEqual(step1.field, .username)

        try await type("email", "two.step@example.com")
        try await h.waitForNavigation { try await h.pressReturn() }
        XCTAssertTrue(h.webView.url?.path.hasSuffix("step2.html") == true)
        XCTAssertTrue(h.captures.isEmpty, "the username step alone isn't offered for saving")

        let step2 = try await focus("password")
        XCTAssertEqual(step2.form, .login)
        XCTAssertEqual(step2.field, .password)
        try await type("password", "Two-Step-Secret-5")
        try await h.pressReturn()
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
        try await h.waitForNavigation { try await h.pressReturn() }
        let fillStep2 = try await focus("password")
        XCTAssertEqual(fillStep2.suggestedLoginID, saved.id)
        let notYet = try await value("password")
        XCTAssertEqual(notYet, "", "the second step isn't filled until asked")
        try await h.autofill.fill(saved.id, into: fillStep2)
        let filled = try await value("password")
        XCTAssertEqual(filled, "Two-Step-Secret-5")
    }

    func testAnotherSitesFrameCannotWipeTheTwoStepUsername() async throws {
        try await h.load(server.url("/step1.html"))
        _ = try await focus("email")
        try await type("email", "kept@example.com")
        try await h.waitForNavigation { try await h.pressReturn() }
        try await h.load(server.url("/step2-framed.html"))
        try await h.waitUntil("the iframe's login form") { h.forms.contains { !$0.frame.isMainFrame } }
        let iframe = h.forms.first { !$0.frame.isMainFrame }!.frame

        // A sign-in inside the other site's frame, typed for real.
        try await type("username", "framed-user", in: iframe.frameInfo)
        try await type("password", "Framed-Secret-1", in: iframe.frameInfo)
        try await h.pressReturn()
        try await h.waitUntil("the frame's capture") { h.captures.contains { $0.origin == localhostOrigin } }

        _ = try await focus("password")
        try await type("password", "Step-Two-Secret-2")
        try await h.pressReturn()
        try await h.waitUntil("the step-two capture") { h.captures.contains { $0.origin == origin } }
        let capture = h.captures.first { $0.origin == origin }!
        XCTAssertEqual(capture.username, "kept@example.com")
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
        try await h.pressReturn()
        try await h.waitUntil("a capture") { !h.captures.isEmpty }
        XCTAssertEqual(h.captures[0].form, .signup)
        XCTAssertEqual(h.captures[0].username, "signup@example.com")
        XCTAssertEqual(h.captures[0].password, generated)
        XCTAssertEqual(h.captures[0].action, .save)

        // Mismatched confirmation: not a password worth saving.
        h.clearEvents()
        try await type("new", "Mismatch-One-1")
        try await type("confirm", "Mismatch-Two-2")
        try await h.pressReturn()
        try await h.settle()
        XCTAssertTrue(h.captures.isEmpty)
    }

    func testHugeLengthLimitsFromThePageAreIgnored() async throws {
        try await h.load(server.url("/signup.html"))
        try await h.page("""
            const el = document.getElementById('new');
            el.setAttribute('minlength', '2000000000');
            el.setAttribute('passwordrules', 'minlength: 2000000000; max-consecutive: 1;');
            """)
        let focus = try await focus("new")
        XCTAssertNil(focus.requirements.minLength, "an absurd minlength is dropped")
        let start = Date()
        let generated = PasswordGenerator.generate(focus.requirements)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
        XCTAssertLessThanOrEqual(generated.count, PasswordGenerator.lengthLimits.upperBound)
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
        // The sandboxed srcdoc frame is ignored entirely.
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
        XCTAssertNil(h.autofill.bestAutomaticLogin(for: frameFocus), "⌘\\ never fills a cross-site frame")

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
        XCTAssertTrue(h.focuses.isEmpty, "synthetic focusin and mousedown events are ignored")

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

    func testNamedElementsCannotHideTheForm() async throws {
        let saved = try h.store.add(origin: origin, username: "user", password: "Clobber-Secret-11")
        try await h.load(server.url("/clobber.html"))
        let clobbered = try await h.pageString("return [document.forms.tagName, document.getElementById('login').elements.tagName].join()")
        XCTAssertEqual(clobbered, "IMG,INPUT", "the fixture really shadows the built-ins")
        try await h.waitUntil("the login form to be found") { h.forms.contains { $0.kinds.contains(.login) } }
        let focus = try await focus("password")
        XCTAssertEqual(focus.form, .login)
        try await h.autofill.fill(saved.id, into: focus)
        let pass = try await value("password")
        XCTAssertEqual(pass, "Clobber-Secret-11")
    }

    func testHiddenFieldsAreNeverOfferedOrFilled() async throws {
        let saved = try h.store.add(origin: origin, username: "user", password: "Hidden-Secret-9")
        try await h.load(server.url("/hidden.html"))
        try await h.settle(0.5)
        for id in ["t-username", "t-password", "o-username", "o-password"] {
            try await h.page("document.getElementById(\(q(id))).focus()")
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

    func testCSSHidingTricksGetNoPopoverAndNoFill() async throws {
        let saved = try h.store.add(origin: origin, username: "user@example.com", password: "Trick-Secret-12")
        try await h.load(server.url("/tricks.html"))
        try await h.settle(0.5)
        for n in 1...11 {
            for prefix in ["u", "p"] {
                // preventScroll: a focus that scrolls the field into view makes it visible.
                try await h.page("document.getElementById('\(prefix)\(n)').focus({ preventScroll: true })")
            }
        }
        try await h.settle(0.6)
        XCTAssertEqual(h.focuses.map(\.fieldID), [], "no hidden field gets a popover")

        // The newsletter box is a username-only form: filling it puts in the email, and the
        // faint password field beside it stays empty.
        let news = try await focus("news-email")
        XCTAssertEqual(news.form, .usernameOnly)
        try await h.autofill.fill(saved.id, into: news)
        let email = try await value("news-email"), hiddenPass = try await value("news-pass")
        XCTAssertEqual(email, "user@example.com")
        XCTAssertEqual(hiddenPass, "")

        // A field moved into another form between the focus and the fill isn't filled.
        let real = try await focus("rp")
        try await h.page("document.getElementById('trap').appendChild(document.getElementById('rp'))")
        do {
            try await h.autofill.fill(saved.id, into: real)
            XCTFail("filled a field that moved to another form")
        } catch {
            XCTAssertEqual(error as? AutofillError, .noField)
        }
        let trapUser = try await value("tu"), movedPass = try await value("rp")
        XCTAssertEqual(trapUser, "")
        XCTAssertEqual(movedPass, "")
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

    func testPageCannotSwapValuesAfterTheUserTypes() async throws {
        try h.store.add(origin: origin, username: "victim", password: "Real-Password-1")
        try await h.load(server.url("/login.html"))
        // The page submits on every keystroke: no click or Return, no capture.
        try await h.page("""
            document.getElementById('password').addEventListener('input', () =>
                document.getElementById('login').requestSubmit());
            """)
        try await type("username", "victim")
        try await type("password", "Sec")
        try await h.settle(0.5)
        XCTAssertTrue(h.captures.isEmpty, "keystrokes alone don't count as a sign-in")

        // The user types; the page swaps in its own password before the real Return.
        try await h.load(server.url("/login.html"))
        try await h.page("""
            const el = document.getElementById('password');
            el.addEventListener('input', () => setTimeout(() => { el.value = 'Attacker-Chosen-2'; }, 0));
            """)
        try await type("username", "victim")
        try await type("password", "Typed-Password-3")
        let swapped = try await value("password")
        XCTAssertEqual(swapped, "Attacker-Chosen-2")
        try await h.pressReturn()
        try await h.settle()
        XCTAssertTrue(h.captures.isEmpty, "a value the user didn't type isn't offered")
        XCTAssertEqual(try h.store.allLogins().first?.password, "Real-Password-1")
    }

    func testCoveredPasswordFieldFillsOnlyTheUsername() async throws {
        let saved = try h.store.add(origin: origin, username: "fold-user", password: "Fold-Secret-1")
        try await h.load(server.url("/fold.html"))
        // Below the fold: scrolled into view and filled.
        try await h.click("username")
        var result = try await h.autofill.fill(saved.id, into: h.focuses.last!)
        XCTAssertEqual(result, .filled)
        var user = try await value("username"), pass = try await value("password")
        XCTAssertEqual(user, "fold-user")
        XCTAssertEqual(pass, "Fold-Secret-1")

        // Under a fixed cookie banner wherever it scrolls: only the username.
        try await h.load(server.url("/fold.html"))
        try await h.page("document.body.classList.add('banner')")
        try await h.click("username")
        result = try await h.autofill.fill(saved.id, into: h.focuses.last!)
        XCTAssertEqual(result, .usernameOnly)
        user = try await value("username")
        pass = try await value("password")
        XCTAssertEqual(user, "fold-user")
        XCTAssertEqual(pass, "")
    }

    func testPasswordNeverGoesIntoASliverOrABlur() async throws {
        let saved = try h.store.add(origin: origin, username: "user@example.com", password: "Sliver-Secret-1")
        try await h.load(server.url("/tricks.html"))
        for n in [12, 13] {
            let focus = try await focus("u\(n)")
            _ = try await h.autofill.fill(saved.id, into: focus)
            let user = try await value("u\(n)"), pass = try await value("p\(n)")
            XCTAssertEqual(user, "user@example.com", "#u\(n)")
            XCTAssertEqual(pass, "", "#p\(n) gets no password")
        }
    }

    func testClickingALabelIsTheUsers() async throws {
        try await h.load(server.url("/label.html"))
        try await h.click("lab")
        let focus = try XCTUnwrap(h.focuses.last)
        XCTAssertEqual(focus.field, .username)
        XCTAssertTrue(focus.isUserInitiated)
    }

    func testDisabledWebViewGetsNothing() async throws {
        let saved = try h.store.add(origin: origin, username: "user", password: "Agent-Tab-1")
        try await h.load(server.url("/login.html"))
        let focus = try await focus("password")
        h.autofill.setDisabled(true, for: h.webView)
        XCTAssertNil(h.autofill.lastFocus(in: h.webView))
        do {
            try await h.autofill.fill(saved.id, into: focus)
            XCTFail("filled a disabled web view")
        } catch {
            XCTAssertEqual(error as? AutofillError, .disabled)
        }
        let before = h.focuses.count
        try await h.page("document.getElementById('username').focus()")
        try await type("password", "Typed-In-Agent-Tab")
        try await h.pressReturn()
        try await h.settle()
        XCTAssertEqual(h.focuses.count, before)
        XCTAssertTrue(h.captures.isEmpty)
    }
}

private final class NoopHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
}
