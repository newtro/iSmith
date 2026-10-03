import Passwords
import WebKit
import XCTest
@testable import iSmith

/// P4 wiring: the save bar on a fixture login submit, saving with a corrected username, the
/// autofill popover's rows, filling through ⌘\ and a popover pick, and agent tabs left alone.
/// Input is real (trusted) mouse and keyboard events in an offscreen window.
@MainActor
final class PasswordWiringTests: XCTestCase {
    private var server: TestHTTPServer!
    private var wired: WiredBrowser!

    private static let login = """
        <!doctype html><title>Sign in</title><body style="margin:40px">
        <form id="f" action="/welcome" method="get">
          <input id="username" name="username" type="email" autocomplete="username" style="display:block;width:240px;height:28px">
          <input id="password" name="password" type="password" autocomplete="current-password" style="display:block;width:240px;height:28px;margin-top:10px">
          <button id="go" type="submit" style="margin-top:10px">Sign in</button>
        </form></body>
        """

    private static let signup = """
        <!doctype html><title>Sign up</title><body style="margin:40px">
        <form id="f" action="/welcome" method="get">
          <input id="username" name="username" type="email" autocomplete="username" style="display:block;width:240px;height:28px">
          <input id="newpw" name="newpw" type="password" autocomplete="new-password" minlength="12" style="display:block;width:240px;height:28px;margin-top:10px">
          <button id="go" type="submit">Create account</button>
        </form></body>
        """

    override func setUp() async throws {
        server = try TestHTTPServer(routes: [
            "/login.html": .html(Self.login),
            "/signup.html": .html(Self.signup),
            "/welcome": .html("<title>Welcome</title><p>Signed in"),
        ])
        try await server.start()
        wired = try WiredBrowser()
    }

    override func tearDown() async throws {
        await wired?.tearDown()
        server?.stop()
    }

    private var origin: Origin { Origin(url: server.url("/"))! }

    private func store() throws -> PasswordStore { try XCTUnwrap(wired.browser.passwords?.store) }

    /// Waits for the script to have looked at the page's forms.
    private func openShown(_ path: String) async throws -> Tab {
        let tab = try await wired.open(server.url(path))
        try wired.show(tab)
        try await Task.sleep(nanoseconds: 400_000_000)
        return tab
    }

    func testSaveBarAppearsOnSubmitAndSavesTheCorrectedUsername() async throws {
        let tab = try await openShown("/login.html")
        try await wired.click("username", in: tab)
        try await wired.type("scott@exampel.com", in: tab)
        try await wired.click("password", in: tab)
        try await wired.type("Correct-Horse-9", in: tab)
        try await wired.pressReturn(in: tab)

        let offered = await eventually { tab.passwordOffer != nil }
        XCTAssertTrue(offered, "the save bar is up")
        let offer = try XCTUnwrap(tab.passwordOffer)
        XCTAssertFalse(offer.isUpdate)
        XCTAssertEqual(offer.username, "scott@exampel.com")
        XCTAssertEqual(offer.capture.origin, origin, "the frame's origin, not the tab's address")
        XCTAssertEqual(offer.siteName, origin.serialized, "an http site is named with its scheme and port")
        XCTAssertFalse(String(describing: offer.capture).contains("Correct-Horse"), "the capture doesn't print its password")

        // The user fixes the username in the bar, then saves.
        offer.username = "scott@example.com "
        wired.browser.savePassword(offer, in: tab)
        XCTAssertNil(tab.passwordOffer, "the bar goes away")
        let saved = try store().allLogins()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.origin, origin)
        XCTAssertEqual(saved.first?.username, "scott@example.com")
        XCTAssertEqual(saved.first?.password, "Correct-Horse-9")

        // Signing in again with the same password asks nothing.
        try await wired.waitForNewPage(tab, path: "/login.html") { tab.webView?.load(URLRequest(url: server.url("/login.html"))) }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await wired.click("username", in: tab)
        wired.browser.passwordUI.close()
        try await wired.type("scott@example.com", in: tab)
        try await wired.click("password", in: tab)
        wired.browser.passwordUI.close()
        try await wired.type("Correct-Horse-9", in: tab)
        try await wired.pressReturn(in: tab)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNil(tab.passwordOffer)

        // "Never for This Site" on a new login: no more offers for this origin.
        try await wired.waitForNewPage(tab, path: "/login.html") { tab.webView?.load(URLRequest(url: server.url("/login.html"))) }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await wired.click("username", in: tab)
        wired.browser.passwordUI.close()
        try await wired.type("someone.else", in: tab)
        try await wired.click("password", in: tab)
        wired.browser.passwordUI.close()
        try await wired.type("Other-Pass-77", in: tab)
        try await wired.pressReturn(in: tab)
        let second = await eventually { tab.passwordOffer != nil }
        XCTAssertTrue(second)
        wired.browser.neverSavePassword(try XCTUnwrap(tab.passwordOffer), in: tab)
        XCTAssertNil(tab.passwordOffer)
        XCTAssertEqual(try store().neverSaveOrigins(), [origin])
        XCTAssertEqual(try store().allLogins().count, 1)
    }

    func testPopoverListsLoginsAndFillWorksThroughTheController() async throws {
        let saved = try store().add(origin: origin, username: "scott@example.com", password: "Saved-Secret-1")
        try store().add(origin: Origin(string: "https://elsewhere.example")!, username: "nope", password: "nope")
        let ui = wired.browser.passwordUI

        let tab = try await openShown("/login.html")
        // A page focusing the field by itself opens nothing.
        _ = try await tab.webView?.evaluateJavaScript("document.getElementById('username').focus(); 1")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(ui.model, "no popover for a programmatic focus")

        // A real click shows this origin's logins only, with no password in the popover.
        try await wired.click("username", in: tab)
        let shown = await eventually { ui.model != nil }
        XCTAssertTrue(shown, "the popover opened for the clicked field")
        XCTAssertEqual(ui.model?.rows.map(\.loginID), [saved.id])
        XCTAssertTrue(ui.isShowing(for: tab.webView))

        // A pick within the first half second is ignored (a page can't move a field under the
        // pointer and turn the next click into a fill).
        ui.model?.choose(0)
        try await Task.sleep(nanoseconds: 200_000_000)
        let early = try await wired.value("password", in: tab)
        XCTAssertEqual(early, "")

        // After that, picking the row fills username and password.
        try await Task.sleep(nanoseconds: 450_000_000)
        ui.model?.choose(0)
        let filled = await eventually { (try? await self.wired.value("password", in: tab)) == "Saved-Secret-1" }
        XCTAssertTrue(filled)
        let user = try await wired.value("username", in: tab)
        XCTAssertEqual(user, "scott@example.com")
        XCTAssertNil(ui.model, "the popover closed")

        // ⌘\ on a fresh page: fills the exact match into the field the user clicked.
        try await wired.waitForNewPage(tab, path: "/login.html") { tab.webView?.load(URLRequest(url: server.url("/login.html"))) }
        try await Task.sleep(nanoseconds: 300_000_000)
        try await wired.click("password", in: tab)
        try await Task.sleep(nanoseconds: 350_000_000)
        ui.fillShortcut(in: tab.webView)
        let shortcut = await eventually { (try? await self.wired.value("password", in: tab)) == "Saved-Secret-1" }
        XCTAssertTrue(shortcut, "⌘\\ filled")
        let shortcutUser = try await wired.value("username", in: tab)
        XCTAssertEqual(shortcutUser, "scott@example.com")

        // Navigating closes the popover.
        try await wired.click("username", in: tab)
        let again = await eventually { ui.model != nil }
        XCTAssertTrue(again)
        try await wired.waitForNewPage(tab, path: "/welcome") { tab.webView?.load(URLRequest(url: server.url("/welcome"))) }
        XCTAssertNil(ui.model, "navigation closed the popover")
    }

    func testSignupFieldsOfferAGeneratedPassword() async throws {
        let ui = wired.browser.passwordUI
        let tab = try await openShown("/signup.html")
        try await wired.click("newpw", in: tab)
        let shown = await eventually { ui.model != nil }
        XCTAssertTrue(shown)
        let row = try XCTUnwrap(ui.model?.rows.last)
        guard case .generated(let password) = row.kind else { return XCTFail("a generated password row") }
        XCTAssertGreaterThanOrEqual(password.count, 12, "honors minlength")
        try await Task.sleep(nanoseconds: 550_000_000)
        ui.model?.choose((ui.model?.rows.count ?? 1) - 1)
        let filled = await eventually { (try? await self.wired.value("newpw", in: tab)) == password }
        XCTAssertTrue(filled)
    }

    /// The Passwords window: revealing needs authentication, which lasts while unlocked and only
    /// counts when the window is key; locking hides the password again.
    func testManagerRevealNeedsAuthenticationAndLocks() async throws {
        let login = try store().add(origin: origin, username: "scott@example.com", password: "Reveal-Me-1")
        let model = PasswordsModel(store: try store(), problem: nil)
        var asked = 0
        var answer = false
        model.authenticate = { _ in asked += 1; return answer }

        await model.reveal(login.id)
        XCTAssertNil(model.revealed, "refused authentication shows nothing")
        answer = true
        await model.reveal(login.id)
        XCTAssertEqual(model.revealed?.password, "Reveal-Me-1")
        XCTAssertEqual(asked, 2)
        await model.reveal(login.id) // hide
        await model.reveal(login.id) // show again within the unlock: no new prompt
        XCTAssertEqual(asked, 2)
        XCTAssertEqual(model.revealed?.password, "Reveal-Me-1")
        model.lock()
        XCTAssertNil(model.revealed)
        XCTAssertFalse(model.isUnlocked)

        // A window that isn't key (the user went elsewhere during the prompt) gets nothing.
        let window = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 10, height: 10), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        model.watch(window)
        await model.reveal(login.id)
        XCTAssertNil(model.revealed)
        XCTAssertFalse(model.isUnlocked)
        XCTAssertEqual(model.rows.map(\.id), [login.id], "the list holds summaries")
    }

    /// Agent-driven tabs (after v1) get no popover, no fill and no save bar.
    func testAgentTabsGetNoAutofill() async throws {
        try store().add(origin: origin, username: "scott@example.com", password: "Saved-Secret-1")
        let ui = wired.browser.passwordUI
        let tab = try await openShown("/login.html")
        wired.browser.setAgentControlled(true, for: tab)
        XCTAssertTrue(try XCTUnwrap(wired.browser.passwords).isDisabled(for: try XCTUnwrap(tab.webView)))

        try await wired.click("username", in: tab)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(ui.model, "no popover")
        ui.fillShortcut(in: tab.webView)
        try await Task.sleep(nanoseconds: 400_000_000)
        let password = try await wired.value("password", in: tab)
        XCTAssertEqual(password, "", "nothing filled")

        try await wired.type("agent@example.com", in: tab)
        try await wired.click("password", in: tab)
        try await wired.type("Agent-Typed-1", in: tab)
        try await wired.pressReturn(in: tab)
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNil(tab.passwordOffer, "no save bar")

        // A new web view for the same tab (a rebuild) stays disabled.
        tab.unload()
        wired.browser.ensureLoaded(tab, space: wired.spaceID)
        let rebuilt = await eventually { tab.webView != nil }
        XCTAssertTrue(rebuilt)
        XCTAssertTrue(try XCTUnwrap(wired.browser.passwords).isDisabled(for: try XCTUnwrap(tab.webView)))
    }
}
