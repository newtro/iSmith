import AgentKit
import AppKit
import BrowserData
import WebKit
import XCTest
@testable import iSmith

/// The agent's browser tools on local fixture pages, through a real `BrowserState`: snapshot
/// numbering, trusted input in a background tab, screenshots, the modes, the sign-in hand-off,
/// the Agent group and taking a tab back, and the activity log.
@MainActor
final class AgentToolsTests: XCTestCase {
    private var wired: WiredBrowser!
    private var server: TestHTTPServer!
    private var host: FakeToolHost!
    private var tools: AgentBrowserTools!
    private let ctx = AgentToolContext(spaceID: "fixture", threadID: "thread-1")

    static let shop = """
        <!doctype html><html><head><title>Fixture Shop</title></head><body>
        <h1>Widget</h1>
        <p>Price: <span id="price">$42.00</span></p>
        <form id="cart" action="/added.html" method="get">
          <label for="qty">Quantity</label><input id="qty" name="qty" value="1">
          <select id="color" name="color" onchange="window.__colorTrusted = event.isTrusted"><option value="r">Red</option><option value="b">Blue</option></select>
          <button id="add" type="submit">Add to cart</button>
        </form>
        <button id="plain" type="button" onclick="document.getElementById('log').textContent = 'clicked:' + event.isTrusted">Show details</button>
        <input id="note" aria-label="Note" oninput="window.__noteTrusted = event.isTrusted">
        <button id="delete" type="button" onclick="document.getElementById('log').textContent = 'deleted'">Delete account</button>
        <div id="log"></div>
        <div id="mail" tabindex="0" style="cursor:pointer">Message from Contoso</div>
        <canvas id="cv" width="200" height="100" style="display:block" onclick="window.__canvas = [event.offsetX, event.offsetY, event.isTrusted]"></canvas>
        <div style="height:3000px"></div>
        <p id="far">Footer text far below</p>
        </body></html>
        """

    override func setUp() async throws {
        server = try TestHTTPServer(routes: [
            "/shop.html": .html(Self.shop),
            "/added.html": .html("<!doctype html><title>Added</title><h1>Added to cart</h1><p>Thanks.</p>"),
            "/login.html": .html("""
                <!doctype html><title>Sign in</title><form action="/added.html"><input name="user" id="user" aria-label="Email">
                <input type="password" id="password" name="password" value="Never-Shown-1"><button>Sign in</button></form>
                <button type="button" id="show" onclick="document.getElementById('password').type = 'text'">Show password</button>
                """),
            "/home.html": .html("<!doctype html><title>Home</title><p>The user's own page.</p>"),
        ])
        try await server.start()
        wired = try WiredBrowser()
        host = FakeToolHost()
        tools = AgentBrowserTools(browser: wired.browser)
        tools.host = host
    }

    override func tearDown() async throws {
        await wired.tearDown()
        server.stop()
    }

    private func call(_ tool: String, _ args: JSONValue = [:]) async -> AgentToolResult {
        await tools.call(tool, arguments: args, context: ctx)
    }

    private func succeeded(_ tool: String, _ args: JSONValue = [:]) async -> Bool {
        await call(tool, args).success
    }

    private func text(_ result: AgentToolResult) -> String {
        result.content.compactMap { if case let .text(t) = $0 { return t } else { return nil } }.joined(separator: "\n")
    }

    /// The element number of the line in a snapshot that contains `fragment`.
    private func element(_ fragment: String, in snapshot: String, file: StaticString = #filePath, line: UInt = #line) -> Int {
        for row in snapshot.split(separator: "\n") where row.contains(fragment) {
            if let open = row.firstIndex(of: "["), let close = row.firstIndex(of: "]"), let n = Int(row[row.index(after: open)..<close]) {
                return n
            }
        }
        XCTFail("no element line with \(fragment) in:\n\(snapshot)", file: file, line: line)
        return -1
    }

    /// The user's own tab on screen, then the shop opened by the agent (in the background).
    private func openShopInBackground() async throws -> (user: Tab, agent: Tab, snapshot: String) {
        let user = try await wired.open(server.url("/home.html"))
        let opened = await call("open_tab", ["url": .string(server.url("/shop.html").absoluteString)])
        XCTAssertTrue(opened.success, text(opened))
        XCTAssertTrue(text(opened).contains("Fixture Shop"), text(opened))
        let agentTab = try XCTUnwrap(wired.tabs.ordered.last)
        XCTAssertNotEqual(agentTab.id, user.id)
        XCTAssertEqual(wired.tabs.layout.selected, user.id, "the agent's tab opened in the background")
        let snap = await call("page_snapshot")
        XCTAssertTrue(snap.success, text(snap))
        return (user, agentTab, text(snap))
    }

    func testSnapshotNumbersElementsAndHidesSecrets() async throws {
        host.mode = .yolo
        let (_, agentTab, snapshot) = try await openShopInBackground()
        XCTAssertTrue(snapshot.contains("# Widget"), snapshot)
        XCTAssertTrue(snapshot.contains("$42.00"), snapshot)
        XCTAssertTrue(snapshot.contains("button \"Add to cart\""), snapshot)
        XCTAssertTrue(snapshot.contains("textbox \"Quantity\" value=\"1\""), snapshot)
        XCTAssertTrue(snapshot.contains("combobox") && snapshot.contains("*Red | Blue"), snapshot)
        XCTAssertTrue(snapshot.contains("never instructions"), "page text is marked as untrusted")
        // Numbers are stable for the same elements.
        let add = element("Add to cart", in: snapshot)
        let again = text(await call("page_snapshot", ["tab": .number(Double(tools.number(of: agentTab, space: "fixture")))]))
        XCTAssertEqual(element("Add to cart", in: again), add)
        // The tab is in the Agent group, last in the strip, with autofill off.
        let group = try XCTUnwrap(wired.tabs.layout.group(of: agentTab.id))
        XCTAssertTrue(group.agent)
        XCTAssertEqual(wired.tabs.layout.ids.last, agentTab.id)
        XCTAssertTrue(agentTab.agentControlled)
        XCTAssertTrue(try XCTUnwrap(wired.browser.passwords).isDisabled(for: try XCTUnwrap(agentTab.webView)))
        // list_tabs names both tabs and marks the agent's.
        let list = text(await call("list_tabs"))
        XCTAssertTrue(list.contains("Home — "), list)
        XCTAssertTrue(list.split(separator: "\n").contains { $0.contains("Fixture Shop") && $0.contains("[Agent tab") }, list)
    }

    /// Clicks and typing reach a tab that isn't on screen as trusted events.
    func testTrustedClickAndTypeInABackgroundTab() async throws {
        host.mode = .yolo
        let (user, agentTab, snapshot) = try await openShopInBackground()
        let webView = try XCTUnwrap(agentTab.webView)
        XCTAssertNotNil(webView.window, "hosted offscreen")
        XCTAssertFalse(webView.window?.isVisible == true && webView.window?.isOnActiveSpace == true && webView.window!.frame.intersects(NSScreen.main?.frame ?? .zero),
                       "never on screen")

        let clicked = await call("click", ["element": .number(Double(element("Show details", in: snapshot)))])
        XCTAssertTrue(clicked.success, text(clicked))
        let log = try await webView.evaluateJavaScript("document.getElementById('log').textContent") as? String
        XCTAssertEqual(log, "clicked:true")

        let typed = await call("type", ["element": .number(Double(element("Note", in: snapshot))), "text": "Hello from the agent"])
        XCTAssertTrue(typed.success, text(typed))
        let value = try await webView.evaluateJavaScript("document.getElementById('note').value") as? String
        XCTAssertEqual(value, "Hello from the agent")
        let trusted = try await webView.evaluateJavaScript("window.__noteTrusted === true") as? Bool
        XCTAssertEqual(trusted, true)

        // Replacing the quantity, then Return submits the form.
        let qty = element("Quantity", in: snapshot)
        let submitted = await call("type", ["element": .number(Double(qty)), "text": "3", "submit": true])
        XCTAssertTrue(submitted.success, text(submitted))
        let landed = await eventually(timeout: 10) { agentTab.url?.path == "/added.html" }
        XCTAssertTrue(landed)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(agentTab.url), resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "qty" }?.value, "3")
        XCTAssertEqual(wired.tabs.layout.selected, user.id, "the user's tab stayed on screen")
    }

    func testSelectScrollPressKeyAndFind() async throws {
        host.mode = .yolo
        let (_, agentTab, snapshot) = try await openShopInBackground()
        let webView = try XCTUnwrap(agentTab.webView)
        let combo = element("combobox", in: snapshot)
        let picked = await call("select", ["element": .number(Double(combo)), "option": "Blue"])
        XCTAssertTrue(picked.success, text(picked))
        let color = try await webView.evaluateJavaScript("document.getElementById('color').value") as? String
        XCTAssertEqual(color, "b")
        let missing = await call("select", ["element": .number(Double(combo)), "option": "Green"])
        XCTAssertFalse(missing.success)
        XCTAssertTrue(text(missing).contains("Red | Blue"), text(missing))

        let scrolled = await call("scroll", ["direction": "down", "screens": 2])
        XCTAssertTrue(scrolled.success, text(scrolled))
        let y = try await webView.evaluateJavaScript("scrollY") as? Double ?? 0
        XCTAssertGreaterThan(y, 300)

        let found = await call("find_text", ["query": "far below"])
        XCTAssertTrue(text(found).contains("Footer text far below"), text(found))

        // Return in the focused quantity field submits the form.
        _ = await call("click", ["element": .number(Double(element("Quantity", in: snapshot)))])
        let pressed = await call("press_key", ["key": "Enter"])
        XCTAssertTrue(pressed.success, text(pressed))
        let landed = await eventually(timeout: 10) { agentTab.url?.path == "/added.html" }
        XCTAssertTrue(landed)
        let waited = await call("wait_for", ["text": "Added to cart", "seconds": 5])
        XCTAssertTrue(waited.success, text(waited))
        let back = await call("go_back")
        XCTAssertTrue(back.success, text(back))
        let returned = await eventually(timeout: 10) { agentTab.url?.path == "/shop.html" }
        XCTAssertTrue(returned)
    }

    func testScreenshotAndClickAt() async throws {
        host.mode = .yolo
        let (_, agentTab, _) = try await openShopInBackground()
        let shot = await call("screenshot")
        XCTAssertTrue(shot.success, text(shot))
        guard case let .image(dataURL)? = shot.content.last else { return XCTFail("no image") }
        XCTAssertTrue(dataURL.hasPrefix("data:image/png;base64,"))
        let data = try XCTUnwrap(Data(base64Encoded: String(dataURL.dropFirst("data:image/png;base64,".count))))
        let image = try XCTUnwrap(NSBitmapImageRep(data: data))
        XCTAssertGreaterThan(image.pixelsWide, 500)
        XCTAssertGreaterThan(image.pixelsHigh, 300)
        // The page isn't blank: some pixels are dark (the heading's text).
        var dark = 0
        for x in stride(from: 0, to: min(image.pixelsWide, 400), by: 2) {
            for y in stride(from: 0, to: min(image.pixelsHigh, 120), by: 2) where (image.colorAt(x: x, y: y)?.brightnessComponent ?? 1) < 0.3 { dark += 1 }
        }
        XCTAssertGreaterThan(dark, 10, "the screenshot shows the page")

        let webView = try XCTUnwrap(agentTab.webView)
        let rect = try await webView.evaluateJavaScript("(() => { const r = document.getElementById('cv').getBoundingClientRect(); return [r.left, r.top]; })()") as? [Double]
        let origin = try XCTUnwrap(rect)
        let clicked = await call("click_at", ["x": .number(origin[0] + 30), "y": .number(origin[1] + 20)])
        XCTAssertTrue(clicked.success, text(clicked))
        let canvas = try await webView.evaluateJavaScript("window.__canvas") as? [Any]
        XCTAssertEqual((canvas?[0] as? NSNumber)?.intValue ?? -1, 30, accuracy: 2)
        XCTAssertEqual((canvas?[1] as? NSNumber)?.intValue ?? -1, 20, accuracy: 2)
        XCTAssertEqual(canvas?[2] as? Bool, true)
    }

    func testModes() async throws {
        host.mode = .yolo
        let (_, agentTab, snapshot) = try await openShopInBackground()
        host.mode = .readOnly
        let webView = try XCTUnwrap(agentTab.webView)
        let details = Double(element("Show details", in: snapshot))
        let add = Double(element("Add to cart", in: snapshot))
        let delete = Double(element("Delete account", in: snapshot))
        func log() async throws -> String { try await webView.evaluateJavaScript("document.getElementById('log').textContent") as? String ?? "" }

        // Read-only: no input, reading and moving around still work.
        let blocked = await call("click", ["element": .number(details)])
        XCTAssertFalse(blocked.success)
        XCTAssertTrue(text(blocked).contains("Read-only"), text(blocked))
        do { let current = try await log(); XCTAssertEqual(current, "") }
        do { let ok = await succeeded("scroll", ["direction": "down"]); XCTAssertTrue(ok) }
        XCTAssertEqual(host.approvals.count, 0)
        // Loading pages is an action too: a read-only agent can't carry what it read elsewhere.
        let tabsBefore = wired.tabs.layout.count
        let noOpen = await call("open_tab", ["url": .string(server.url("/home.html").absoluteString)])
        XCTAssertFalse(noOpen.success)
        XCTAssertEqual(wired.tabs.layout.count, tabsBefore)
        let noNavigate = await call("navigate", ["url": .string(server.url("/home.html").absoluteString)])
        XCTAssertFalse(noNavigate.success)
        XCTAssertEqual(agentTab.url?.path, "/shop.html")

        // Ask: page loads ask too.
        host.mode = .ask
        host.approve = false
        let askedOpen = await call("open_tab", ["url": .string(server.url("/home.html").absoluteString)])
        XCTAssertFalse(askedOpen.success)
        XCTAssertEqual(host.approvals.count, 1)
        XCTAssertNil(host.approvals.first?.tabID)
        XCTAssertEqual(wired.tabs.layout.count, tabsBefore)
        host.approvals = []

        // Ask: every input asks; Deny does nothing, Allow goes ahead.
        host.mode = .ask
        host.approve = false
        let denied = await call("click", ["element": .number(details)])
        XCTAssertFalse(denied.success)
        XCTAssertTrue(text(denied).contains("declined"), text(denied))
        do { let current = try await log(); XCTAssertEqual(current, "") }
        host.approve = true
        let allowed = await call("click", ["element": .number(details)])
        XCTAssertTrue(allowed.success, text(allowed))
        do { let current = try await log(); XCTAssertEqual(current, "clicked:true") }
        XCTAssertEqual(host.approvals.count, 2)
        XCTAssertTrue(host.approvals.last?.action.contains("Show details") == true)

        // Confirm submits: an ordinary click is free; deleting and submitting ask.
        host.mode = .confirmSubmits
        host.approvals = []
        do { let ok = await succeeded("click", ["element": .number(details)]); XCTAssertTrue(ok) }
        XCTAssertEqual(host.approvals.count, 0)
        host.approve = false
        do { let ok = await succeeded("click", ["element": .number(delete)]); XCTAssertFalse(ok) }
        XCTAssertEqual(host.approvals.count, 1)
        do { let current = try await log(); XCTAssertNotEqual(current, "deleted") }
        do { let ok = await succeeded("click", ["element": .number(add)]); XCTAssertFalse(ok) }
        XCTAssertEqual(host.approvals.count, 2)
        XCTAssertEqual(agentTab.url?.path, "/shop.html", "the form wasn't submitted")
        // Typing is free; typing and pressing Return asks.
        do { let ok = await succeeded("type", ["element": .number(Double(element("Note", in: snapshot))), "text": "x"]); XCTAssertTrue(ok) }
        XCTAssertEqual(host.approvals.count, 2)
        do { let ok = await succeeded("type", ["element": .number(Double(element("Quantity", in: snapshot))), "text": "2", "submit": true]); XCTAssertFalse(ok) }
        XCTAssertEqual(host.approvals.count, 3)

        // Outside a text field, Delete deletes (the selected mail, say): it asks.
        host.approve = true
        let focusMail = await succeeded("click", ["element": .number(Double(element("Message from Contoso", in: snapshot)))])
        XCTAssertTrue(focusMail)
        host.approve = false
        let deleteKey = await call("press_key", ["key": "Delete"])
        XCTAssertFalse(deleteKey.success)
        XCTAssertEqual(host.approvals.count, 4)
        // Opening a site the space doesn't have open asks; one it has is free.
        let newSite = await call("open_tab", ["url": "http://localhost:9/"])
        XCTAssertFalse(newSite.success)
        XCTAssertEqual(host.approvals.count, 5)

        // YOLO: nothing asks.
        host.mode = .yolo
        host.approvals = []
        do { let ok = await succeeded("click", ["element": .number(delete)]); XCTAssertTrue(ok) }
        do { let current = try await log(); XCTAssertEqual(current, "deleted") }
        XCTAssertEqual(host.approvals.count, 0)

        // Everything is in the activity log, with the outcome.
        let activity = try XCTUnwrap(wired.browser.data?.agent.activity(space: "fixture"))
        XCTAssertTrue(activity.contains { $0.tool == "click" && $0.outcome == .blocked })
        XCTAssertTrue(activity.contains { $0.tool == "click" && $0.outcome == .denied })
        XCTAssertTrue(activity.contains { $0.tool == "click" && $0.outcome == .done && $0.target.contains("Delete account") })
        XCTAssertTrue(activity.contains { $0.tool == "type" && $0.target.hasSuffix("1 characters") }, "typed text isn't logged, only its length")
        XCTAssertFalse(activity.contains { $0.target.contains("Hello") })
    }

    /// A sign-in page hands off to the user: autofill comes back on for them while the agent
    /// waits, and goes off again after Continue.
    func testSignInHandOff() async throws {
        host.mode = .yolo
        let (_, agentTab, _) = try await openShopInBackground()
        var duringHandOff: (controlled: Bool, disabled: Bool)?
        host.onHandOff = { [weak self] in
            guard let self, let webView = agentTab.webView else { return }
            duringHandOff = (agentTab.agentControlled, self.wired.browser.passwords?.isDisabled(for: webView) ?? true)
        }
        let result = await call("navigate", ["url": .string(server.url("/login.html").absoluteString)])
        XCTAssertTrue(result.success, text(result))
        XCTAssertEqual(host.handOffs.count, 1)
        XCTAssertTrue(host.handOffs.first?.message.contains("sign-in page") == true)
        XCTAssertEqual(duringHandOff?.controlled, false, "the user is in control during the hand-off")
        XCTAssertEqual(duringHandOff?.disabled, false, "autofill works for the user")
        XCTAssertTrue(text(result).contains("pressed Continue"), text(result))
        XCTAssertTrue(agentTab.agentControlled, "back to the agent")
        XCTAssertTrue(try XCTUnwrap(wired.browser.passwords).isDisabled(for: try XCTUnwrap(agentTab.webView)))
        // The same page doesn't stop the agent twice; typing into the password field is refused.
        let snap = text(await call("page_snapshot"))
        XCTAssertEqual(host.handOffs.count, 1)
        XCTAssertTrue(snap.contains("password field, value hidden"), snap)
        XCTAssertFalse(snap.contains("Never-Shown-1"), "a password's value never reaches the agent")
        let refused = await call("type", ["element": .number(Double(element("password field", in: snap))), "text": "guess"])
        XCTAssertFalse(refused.success)
        XCTAssertTrue(text(refused).contains("password"), text(refused))

        // Stop during a hand-off (in a new tab) ends the task.
        host.continueHandOff = false
        let stopped = await call("open_tab", ["url": .string(server.url("/login.html").absoluteString)])
        XCTAssertFalse(stopped.success)
        XCTAssertEqual(host.stoppedTurns, 1, "Stop on a hand-off stops the turn")
        XCTAssertTrue(text(stopped).contains("stopped"), text(stopped))
    }

    /// The agent acting on the user's tab moves it into the Agent group; the user taking it back
    /// out keeps it theirs.
    func testAdoptingAndTakingBackATab() async throws {
        host.mode = .yolo
        let user = try await wired.open(server.url("/shop.html"))
        XCTAssertFalse(user.agentControlled)
        let snap = text(await call("page_snapshot"))
        XCTAssertNil(wired.tabs.layout.group(of: user.id), "reading doesn't adopt")
        do { let ok = await succeeded("click", ["element": .number(Double(element("Show details", in: snap)))]); XCTAssertTrue(ok) }
        XCTAssertEqual(wired.tabs.layout.group(of: user.id)?.agent, true, "acting adopts the tab")
        XCTAssertTrue(user.agentControlled)

        wired.tabs.update { $0.removeFromGroup([user.id]) }
        XCTAssertFalse(user.agentControlled, "taken back")
        XCTAssertTrue(user.agentReleased)
        XCTAssertFalse(try XCTUnwrap(wired.browser.passwords).isDisabled(for: try XCTUnwrap(user.webView)))
        let refused = await call("click", ["element": .number(Double(element("Show details", in: snap)))])
        XCTAssertFalse(refused.success)
        XCTAssertTrue(text(refused).contains("took this tab back"), text(refused))
        do { let ok = await succeeded("page_snapshot"); XCTAssertTrue(ok, "it can still read it") }

        // Closing: only Agent tabs.
        let n = tools.number(of: user, space: "fixture")
        let notClosed = await call("close_tab", ["tab": .number(Double(n))])
        XCTAssertFalse(notClosed.success)
        _ = await call("open_tab", ["url": .string(server.url("/home.html").absoluteString)])
        let agentTab = try XCTUnwrap(wired.tabs.ordered.last)
        let closed = await call("close_tab", ["tab": .number(Double(tools.number(of: agentTab, space: "fixture")))])
        XCTAssertTrue(closed.success, text(closed))
        XCTAssertNil(wired.tabs.tab(agentTab.id))
    }

    /// The Agent group survives a session round trip and its tabs come back agent-controlled.
    func testAgentGroupIsSaved() async throws {
        host.mode = .yolo
        _ = try await openShopInBackground()
        let record = wired.window.record(spaceOrder: ["fixture"])
        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(WindowRecord.self, from: data)
        let restored = SpaceTabs.restore(try XCTUnwrap(decoded.spaces.first))
        wired.browser.hook(restored)
        let agentTab = try XCTUnwrap(restored.ordered.last)
        XCTAssertEqual(restored.layout.group(of: agentTab.id)?.agent, true)
        XCTAssertTrue(agentTab.agentControlled)
        XCTAssertEqual(decoded.agentDock, wired.window.agentDock)
    }

    /// A password filled in (by the user, during a hand-off) stays out of the agent's reach, even
    /// after a "show password" toggle turns the field into text: no value in the snapshot, no
    /// screenshots, and no ⌘ shortcuts.
    func testSecretsStayHidden() async throws {
        host.mode = .yolo
        _ = try await openShopInBackground()
        _ = await call("navigate", ["url": .string(server.url("/login.html").absoluteString)])
        let shot = await call("screenshot")
        XCTAssertFalse(shot.success, "a filled password field turns screenshots off")
        XCTAssertFalse(shot.content.contains { if case .image = $0 { return true } else { return false } })
        let snap = text(await call("page_snapshot"))
        let shown = await succeeded("click", ["element": .number(Double(element("Show password", in: snap)))])
        XCTAssertTrue(shown)
        let after = text(await call("page_snapshot"))
        XCTAssertFalse(after.contains("Never-Shown-1"), after)
        XCTAssertTrue(after.contains("value hidden"), after)
        let paste = await call("press_key", ["key": "v", "modifiers": ["cmd"]])
        XCTAssertFalse(paste.success)
        XCTAssertTrue(text(paste).contains("cmd"), text(paste))
        let word = await succeeded("press_key", ["key": "ArrowLeft", "modifiers": ["alt"]])
        XCTAssertTrue(word)
    }

    /// What the user approved is what gets clicked: if the page swaps the element while the card
    /// is up, nothing is clicked.
    func testApprovedClickIsCheckedAgain() async throws {
        host.mode = .yolo
        let (_, agentTab, snapshot) = try await openShopInBackground()
        let webView = try XCTUnwrap(agentTab.webView)
        host.mode = .ask
        host.onApprove = {
            _ = try? await webView.evaluateJavaScript("document.getElementById('plain').textContent = 'Pay now'")
        }
        let result = await call("click", ["element": .number(Double(element("Show details", in: snapshot)))])
        XCTAssertFalse(result.success)
        XCTAssertTrue(text(result).contains("page changed"), text(result))
        let log = try await webView.evaluateJavaScript("document.getElementById('log').textContent") as? String
        XCTAssertEqual(log, "")
        // Confirm submits: a page load carrying data to a site that isn't open asks.
        host.mode = .confirmSubmits
        host.onApprove = nil
        host.approve = false
        host.approvals = []
        let away = await call("navigate", ["url": "http://localhost:9/collect?data=secret"])
        XCTAssertFalse(away.success)
        XCTAssertEqual(host.approvals.count, 1)
        let same = await succeeded("navigate", ["url": .string(server.url("/home.html").absoluteString + "?q=1")])
        XCTAssertTrue(same, "the same site is free")
    }

    func testSubmitIntentHeuristics() {
        XCTAssertEqual(AgentPolicy.decide(tool: "page_snapshot", mode: .readOnly, intent: nil), .allow)
        if case .block = AgentPolicy.decide(tool: "navigate", mode: .readOnly, intent: nil) {} else { XCTFail() }
        if case .ask = AgentPolicy.decide(tool: "open_tab", mode: .ask, intent: nil) {} else { XCTFail() }
        XCTAssertEqual(AgentPolicy.decide(tool: "navigate", mode: .confirmSubmits, intent: nil), .allow)
        XCTAssertEqual(AgentPolicy.decide(tool: "scroll", mode: .readOnly, intent: nil), .allow)
        if case .block = AgentPolicy.decide(tool: "close_tab", mode: .readOnly, intent: nil) {} else { XCTFail() }
        if case .block = AgentPolicy.decide(tool: "type", mode: .readOnly, intent: nil) {} else { XCTFail() }
        if case .ask = AgentPolicy.decide(tool: "click", mode: .ask, intent: nil) {} else { XCTFail() }
        XCTAssertEqual(AgentPolicy.decide(tool: "click", mode: .confirmSubmits, intent: nil), .allow)
        if case .ask = AgentPolicy.decide(tool: "click", mode: .confirmSubmits, intent: "send") {} else { XCTFail() }
        XCTAssertEqual(AgentPolicy.decide(tool: "click", mode: .yolo, intent: "delete"), .allow)
    }
}

/// Stands in for the panel: the mode, and scripted answers to approvals and hand-offs.
@MainActor
final class FakeToolHost: AgentToolHost {
    var mode: AgentMode = .yolo
    var approve = true
    var continueHandOff = true
    var approvals: [BrowserApprovalRequest] = []
    var handOffs: [HandOffRequest] = []
    var onHandOff: (() -> Void)?
    var onApprove: (() async -> Void)?

    func mode(for spaceID: String) -> AgentMode { mode }

    func approveBrowserAction(_ request: BrowserApprovalRequest) async -> Bool {
        approvals.append(request)
        await onApprove?()
        return approve
    }

    var stoppedTurns = 0
    func stopTurn(in spaceID: String) { stoppedTurns += 1 }

    func handOff(_ request: HandOffRequest) async -> Bool {
        handOffs.append(request)
        onHandOff?()
        return continueHandOff
    }
}
