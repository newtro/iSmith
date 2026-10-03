import AppKit
import Routing
import SignInSync
import XCTest
@testable import iSmith

/// P6: links from other apps land in the right space and window, moves teach rules, the Dock's
/// "Open in Space", and the default-browser seam (never the Mac's real setting).
///
/// The tests are synchronous on purpose: the web views `openTab` schedules don't get to run
/// before `closeEverything()` closes their tabs, so no test loads a real site. tearDown then
/// deletes the spaces' WebKit stores.
@MainActor
final class LinkRoutingTests: XCTestCase {
    private var dir: URL!
    private var browser: BrowserState!
    private var contoso: String!
    private var fabrikam: String!
    private let personal = "personal"
    /// Tabs closed by `closeEverything()`, whose web view tasks tearDown waits for.
    private var closed: [Tab] = []

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("iSmithP6Tests-\(UUID().uuidString)", isDirectory: true)
        let paths = AppPaths(dataDir: dir, spikeDir: nil)
        let first = BrowserState(paths: paths, keyStore: InMemoryKeyStore())
        contoso = first.manager.createSpace(name: "Contoso", color: 1, home: "", choices: [:], newNames: [:]).id
        fabrikam = first.manager.createSpace(name: "Fabrikam", color: 2, home: "", choices: [:], newNames: [:]).id
        // A browser started with the three spaces.
        browser = BrowserState(paths: paths, keyStore: InMemoryKeyStore())
        XCTAssertEqual(browser.spaces.map(\.id), [personal, contoso, fabrikam])
    }

    override func tearDown() async throws {
        closeEverything()
        // Web views that started building finish (and find their tab gone), then the stores go.
        try await Task.sleep(nanoseconds: 200_000_000)
        for _ in 0..<200 where closed.contains(where: \.isBuilding) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(closed.allSatisfy { $0.webView == nil }, "no test tab got a web view")
        for space in browser.spaces.map(\.id) { await browser.manager.deleteSpace(space).value }
        browser = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// Closes every tab before its web view is made.
    private func closeEverything() {
        for window in browser.windows {
            for tabs in window.spaces.values {
                for tab in tabs.ordered {
                    closed.append(tab)
                    browser.closeTab(tab.id, in: tabs)
                }
            }
        }
    }

    private func url(_ s: String) -> URL { URL(string: s)! }

    private func tabs(_ window: WindowState, _ space: String) -> [Tab] { window.spaces[space]?.ordered ?? [] }

    // MARK: - Incoming links

    func testIncomingLinksOpenInTheRoutedSpace() throws {
        browser.routing.store.addRule(RoutingRule(pattern: try URLPattern(parsing: "dev.azure.com/contoso-dev"), space: contoso))
        let window = browser.newWindow(space: personal)
        browser.lastActiveWindow = window

        // A rule: a new tab in Contoso, selected, and the window switches to Contoso.
        let azure = url("https://dev.azure.com/contoso-dev/Storefront/_workitems/edit/123")
        let opened = try XCTUnwrap(browser.openIncoming(azure))
        XCTAssertTrue(opened.window === window)
        XCTAssertEqual(window.activeSpaceID, contoso)
        XCTAssertEqual(tabs(window, contoso).map(\.url), [azure], "only the link: no home page tab as well")
        XCTAssertEqual(window.spaces[contoso]?.layout.selected, opened.tab.id)
        XCTAssertTrue(opened.tab.isBuilding, "one web view is on its way")

        // No rule: the Default space (unset: the first space).
        let other = url("https://example.com/page")
        XCTAssertEqual(browser.openIncoming(other)?.tab.url, other)
        XCTAssertEqual(window.activeSpaceID, personal)
        XCTAssertTrue(tabs(window, personal).contains { $0.url == other })

        // The Default space setting.
        browser.routing.store.setDefaultSpace(fabrikam)
        browser.openIncoming(url("https://example.org/"))
        XCTAssertEqual(window.activeSpaceID, fabrikam)
        XCTAssertEqual(tabs(window, fabrikam).map(\.url), [url("https://example.org/")])

        // An HTML file opens in the Default space; other schemes aren't taken.
        let file = URL(fileURLWithPath: "/tmp/page.html")
        browser.routing.store.setDefaultSpace(contoso)
        XCTAssertEqual(browser.openIncoming(file)?.tab.url, file)
        XCTAssertEqual(window.activeSpaceID, contoso)
        XCTAssertNil(browser.openIncoming(url("mailto:someone@example.com")))
        XCTAssertNil(browser.openIncoming(url("javascript:alert(1)")))
        closeEverything()
    }

    func testOutlookLinksGoWhereOutlookWasLastUsed() throws {
        // The window counts as the one in use (the test host has no key window).
        browser.routing.isInUse = { _ in true }
        let window = browser.newWindow(space: personal)
        browser.lastActiveWindow = window
        let mail = url("https://outlook.office.com/mail/inbox/id/AAQkAG")
        XCTAssertNotNil(browser.openIncoming(mail))
        XCTAssertEqual(window.activeSpaceID, personal, "never used: the Default space")
        closeEverything()

        // Outlook on screen in Fabrikam: Outlook links go there.
        browser.openTab(in: window, space: fabrikam, url: url("https://outlook.office.com/mail/"))
        browser.select(try XCTUnwrap(browser.space(fabrikam)), in: window)
        browser.select(try XCTUnwrap(browser.space(personal)), in: window)
        browser.openIncoming(mail)
        XCTAssertEqual(window.activeSpaceID, fabrikam)
        XCTAssertEqual(tabs(window, fabrikam).last?.url, mail)

        // Moving an Outlook tab to Contoso makes Contoso the last used.
        let outlookTab = try XCTUnwrap(tabs(window, fabrikam).first)
        browser.moveTabs([outlookTab.id], from: try XCTUnwrap(window.spaces[fabrikam]), in: window, toSpace: contoso)
        browser.openIncoming(url("https://outlook.office.com/calendar/item/1"))
        XCTAssertEqual(window.activeSpaceID, contoso)

        // A rule still wins.
        browser.routing.store.addRule(RoutingRule(pattern: try URLPattern(parsing: "outlook.office.com"), space: personal))
        browser.openIncoming(mail)
        XCTAssertEqual(window.activeSpaceID, personal)
        closeEverything()
    }

    /// A link goes to the window already showing its space; otherwise the current window switches.
    func testIncomingLinkPicksTheWindow() throws {
        browser.routing.store.addRule(RoutingRule(pattern: try URLPattern(parsing: "dev.azure.com/contoso-dev"), space: contoso))
        let front = browser.newWindow(space: personal)
        let onContoso = browser.newWindow(space: contoso)
        browser.lastActiveWindow = front
        let opened = try XCTUnwrap(browser.openIncoming(url("https://dev.azure.com/contoso-dev/x")))
        XCTAssertTrue(opened.window === onContoso, "the window showing Contoso")
        XCTAssertEqual(front.activeSpaceID, personal, "the other window is left alone")

        let fabrikamLink = RoutingRule(pattern: try URLPattern(parsing: "*.fabrikam.com"), space: fabrikam)
        browser.routing.store.addRule(fabrikamLink)
        let second = try XCTUnwrap(browser.openIncoming(url("https://files.fabrikam.com/a")))
        XCTAssertTrue(second.window === front, "no window shows Fabrikam: the current one switches")
        XCTAssertEqual(front.activeSpaceID, fabrikam)

        XCTAssertTrue(BrowserState.incomingWindow(for: "x", windows: [], current: nil) == nil)
        closeEverything()
    }

    /// With no window open, a link gets a new window showing it alone (no home page tab).
    func testLinkWithNoWindowOpensAWindowWithJustTheLink() throws {
        browser.routing.store.addRule(RoutingRule(pattern: try URLPattern(parsing: "dev.azure.com/contoso-dev"), space: contoso))
        XCTAssertTrue(browser.windows.isEmpty)
        let link = url("https://dev.azure.com/contoso-dev/x")
        let opened = try XCTUnwrap(browser.openIncoming(link))
        XCTAssertEqual(browser.windows.count, 1)
        XCTAssertEqual(opened.window.activeSpaceID, contoso)
        XCTAssertEqual(opened.window.allTabs.map(\.url), [link])
        closeEverything()
    }

    /// A second Outlook link into a space that already keeps Outlook alive opens as an ordinary
    /// tab; the first one in a space is kept alive as usual.
    func testOutlookLinksDontPileUpKeptAliveCopies() throws {
        let window = browser.newWindow(space: personal)
        browser.lastActiveWindow = window
        let first = try XCTUnwrap(browser.openIncoming(url("https://outlook.office.com/mail/inbox/id/1"))).tab
        XCTAssertNil(first.keepAliveSetting)
        XCTAssertTrue(first.keepAlive)
        let second = try XCTUnwrap(browser.openIncoming(url("https://outlook.office.com/mail/inbox/id/2"))).tab
        XCTAssertEqual(second.keepAliveSetting, false)
        XCTAssertFalse(second.keepAlive)
        XCTAssertNil(second.record(group: nil).keepAlive, "routing's choice isn't saved")
        // Teams links (meetings) always stay kept alive.
        _ = browser.openIncoming(url("https://teams.microsoft.com/l/chat/1"))
        let meeting = try XCTUnwrap(browser.openIncoming(url("https://teams.microsoft.com/l/meetup-join/19%3ameeting"))).tab
        XCTAssertTrue(meeting.keepAlive)
        // Closing the kept-alive Outlook gives the other one Keep alive back.
        let third = try XCTUnwrap(browser.openIncoming(url("https://outlook.office.com/mail/inbox/id/3"))).tab
        XCTAssertFalse(third.keepAlive)
        browser.closeTab(first.id, in: try XCTUnwrap(window.spaces[personal]))
        XCTAssertTrue(second.keepAlive)
        XCTAssertTrue(third.keepAlive)
        // Moving a lowered tab to another space: it follows its page there.
        let fourth = try XCTUnwrap(browser.openIncoming(url("https://outlook.office.com/mail/inbox/id/4"))).tab
        XCTAssertFalse(fourth.keepAlive)
        browser.moveTabs([fourth.id], from: try XCTUnwrap(window.spaces[personal]), in: window, toSpace: fabrikam)
        XCTAssertTrue(fourth.keepAlive)
        XCTAssertNil(fourth.keepAliveSetting)
        closeEverything()
    }

    /// Safe Links: routed by the link inside; the wrapper is what opens.
    func testSafeLinksRouteByTheLinkInside() throws {
        browser.routing.store.addRule(RoutingRule(pattern: try URLPattern(parsing: "dev.azure.com/contoso-dev"), space: contoso))
        let window = browser.newWindow(space: personal)
        browser.lastActiveWindow = window
        let wrapped = url("https://nam12.safelinks.protection.outlook.com/?url=https%3A%2F%2Fdev.azure.com%2Fcontoso-dev%2Fx&data=1")
        let opened = try XCTUnwrap(browser.openIncoming(wrapped))
        XCTAssertEqual(window.activeSpaceID, contoso)
        XCTAssertEqual(opened.tab.url, wrapped)
        closeEverything()
    }

    /// A link that ended on a sign-in page is loaded again when moved; one still on its site keeps
    /// its history.
    func testMovedLinkReloadsTheLinkNotTheRedirect() throws {
        let window = browser.newWindow(space: personal)
        browser.lastActiveWindow = window
        let link = url("https://dev.azure.com/contoso-dev/x")
        let opened = try XCTUnwrap(browser.openIncoming(link))
        XCTAssertEqual(browser.linkToReload(opened.tab), link, "still the link: it loads again in its new space")
        let redirected = Tab(url: url("https://login.microsoftonline.com/common/oauth2/authorize?state=abc"))
        browser.routing.linkArrived(redirected.id, url: link, openTabs: [opened.tab.id])
        XCTAssertEqual(browser.linkToReload(redirected), link)
        XCTAssertNil(browser.linkToReload(Tab(url: link)), "not from another app")
        browser.routing.forget(opened.tab.id) // a link followed in the page
        XCTAssertNil(browser.linkToReload(opened.tab), "moved on: keeps its own history")
        closeEverything()
    }

    /// Only the tab you're using marks Outlook's space: a page committing in a window that isn't
    /// key (here, none is) doesn't.
    func testBackgroundCommitsDontChangeLastUsed() throws {
        var inUse = false
        browser.routing.isInUse = { _ in inUse }
        let window = browser.newWindow(space: fabrikam)
        let outlook = browser.openTab(in: window, space: fabrikam, url: nil)
        let mail = url("https://outlook.office.com/mail/")
        browser.noteVisibleUse(of: mail, tab: outlook, space: fabrikam)
        browser.select(try XCTUnwrap(browser.space(fabrikam)), in: window)
        XCTAssertTrue(browser.routing.store.state.lastUsed.isEmpty, "a window you aren't using (or a restore at launch)")
        inUse = true
        let other = browser.openTab(in: window, space: fabrikam, url: nil, select: false)
        browser.noteVisibleUse(of: mail, tab: other, space: fabrikam)
        XCTAssertTrue(browser.routing.store.state.lastUsed.isEmpty, "a background tab")
        browser.noteVisibleUse(of: mail, tab: outlook, space: fabrikam)
        XCTAssertEqual(browser.routing.store.state.lastUsed, ["outlook": fabrikam], "the tab on screen in the window in use")
        closeEverything()
    }

    // MARK: - Learning

    func testMovingTwoLinksOffersARule() throws {
        let window = browser.newWindow(space: personal)
        browser.lastActiveWindow = window
        func arriveAndMove(_ link: String) throws {
            let opened = try XCTUnwrap(browser.openIncoming(url(link)))
            XCTAssertEqual(window.activeSpaceID, personal)
            browser.moveTabs([opened.tab.id], from: try XCTUnwrap(window.spaces[personal]), in: window, toSpace: contoso)
            browser.select(try XCTUnwrap(browser.space(personal)), in: window)
        }
        try arriveAndMove("https://dev.azure.com/contoso-dev/Storefront/_workitems/edit/1")
        XCTAssertNil(browser.routing.offer, "once isn't enough")

        // A tab that didn't come from another app teaches nothing.
        let own = browser.openTab(in: window, space: personal, url: url("https://dev.azure.com/contoso-dev/own"))
        browser.moveTabs([own.id], from: try XCTUnwrap(window.spaces[personal]), in: window, toSpace: contoso)
        XCTAssertNil(browser.routing.offer)

        // A link you then typed over in its tab teaches nothing either.
        let retyped = try XCTUnwrap(browser.openIncoming(url("https://dev.azure.com/contoso-dev/z")))
        browser.navigate(retyped.tab, in: try XCTUnwrap(window.spaces[personal]), to: url("https://news.example.com"), typed: true)
        browser.moveTabs([retyped.tab.id], from: try XCTUnwrap(window.spaces[personal]), in: window, toSpace: contoso)
        XCTAssertNil(browser.routing.offer)

        try arriveAndMove("https://dev.azure.com/contoso-dev/Storefront/_git/repo")
        let offer = try XCTUnwrap(browser.routing.offer)
        XCTAssertEqual(offer.suggestion, RuleSuggestion(pattern: try URLPattern(parsing: "dev.azure.com/contoso-dev"), space: contoso))
        XCTAssertEqual(offer.window, window.id, "offered in the window the tab moved in")

        browser.routing.answer(offer, accept: true)
        XCTAssertNil(browser.routing.offer)
        XCTAssertEqual(browser.routing.store.state.rules.map(\.space), [contoso])
        browser.openIncoming(url("https://dev.azure.com/contoso-dev/next"))
        XCTAssertEqual(window.activeSpaceID, contoso, "the accepted rule routes the next link")

        // The rule is in routing.json for the next launch.
        XCTAssertEqual(RoutingStore(fileURL: AppPaths(dataDir: dir, spikeDir: nil).routingURL).state.rules.count, 1)
        closeEverything()
    }

    func testNeverAndNotNow() throws {
        let window = browser.newWindow(space: personal)
        browser.lastActiveWindow = window
        func arriveAndMove() throws {
            let opened = try XCTUnwrap(browser.openIncoming(url("https://github.com/contoso-dev/repo")))
            browser.moveTabs([opened.tab.id], from: try XCTUnwrap(window.spaces[personal]), in: window, toSpace: fabrikam)
            browser.select(try XCTUnwrap(browser.space(personal)), in: window)
        }
        try arriveAndMove()
        try arriveAndMove()
        browser.routing.answer(try XCTUnwrap(browser.routing.offer), accept: false)
        try arriveAndMove()
        XCTAssertNil(browser.routing.offer, "Not now: two more moves")
        try arriveAndMove()
        browser.routing.answer(try XCTUnwrap(browser.routing.offer), accept: false, never: true)
        try arriveAndMove()
        try arriveAndMove()
        XCTAssertNil(browser.routing.offer, "Never")
        XCTAssertTrue(browser.routing.store.state.rules.isEmpty)
        closeEverything()
    }

    func testDeletingASpaceDropsItsRules() throws {
        let store = browser.routing.store
        store.addRule(RoutingRule(pattern: try URLPattern(parsing: "dev.azure.com"), space: contoso))
        store.setDefaultSpace(contoso)
        browser.removeSpace(contoso)
        XCTAssertTrue(store.state.rules.isEmpty)
        XCTAssertNil(store.state.defaultSpace)
    }

    // MARK: - Dock menu

    func testDockMenuOpensTheFrontTabInAnotherSpace() throws {
        let window = browser.newWindow(space: personal)
        browser.lastActiveWindow = window
        closeEverything()
        XCTAssertNil(browser.dockMenu(), "no tab, no menu")
        let tab = browser.openTab(in: window, space: personal, url: url("https://example.com/report"), title: "Report")
        let menu = try XCTUnwrap(browser.dockMenu())
        let open = try XCTUnwrap(menu.items.first)
        XCTAssertEqual(open.title, "Open in Space")
        let items = try XCTUnwrap(open.submenu?.items)
        XCTAssertEqual(items.first?.title, "Report")
        XCTAssertFalse(items.first?.isEnabled ?? true)
        XCTAssertEqual(items.dropFirst(2).map(\.title), ["Contoso", "Fabrikam"], "every other space")

        let toFabrikam = try XCTUnwrap(items.first { $0.title == "Fabrikam" })
        _ = (toFabrikam.target as? NSObject)?.perform(toFabrikam.action, with: toFabrikam)
        XCTAssertEqual(window.activeSpaceID, fabrikam, "the window shows the tab's new space")
        XCTAssertEqual(tabs(window, fabrikam).map(\.id), [tab.id])
        XCTAssertEqual(window.spaces[fabrikam]?.layout.selected, tab.id)
        XCTAssertTrue(tab.isBuilding, "one web view on its way, so showing the space didn't start a second")
        XCTAssertTrue(tabs(window, personal).isEmpty)
        closeEverything()
    }

    // MARK: - Default browser seam

    /// A fake LaunchServices: scheme → handler bundle id.
    private final class FakeLaunchServices {
        var handlers: [String: String] = ["http": "com.brave.Browser", "https": "com.brave.Browser"]
        var calls: [(URL, String)] = []
        /// macOS sets https too when http changes (as it does for browsers).
        var linksSchemes = true
        var refuse = false

        func seam(app: URL = URL(fileURLWithPath: "/Applications/iSmith Dev.app")) -> DefaultBrowser {
            DefaultBrowser(appURL: app, bundleID: "com.scottsmith.ismith.debug",
                           handler: { [unowned self] scheme in self.handlers[scheme].map { URL(fileURLWithPath: "/Apps/\($0).app") } },
                           setHandler: { [unowned self] app, scheme in
                               self.calls.append((app, scheme))
                               if self.refuse { throw NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError) }
                               self.handlers[scheme] = "com.scottsmith.ismith.debug"
                               if self.linksSchemes, scheme == "http" { self.handlers["https"] = "com.scottsmith.ismith.debug" }
                           },
                           bundleIDOf: { $0.deletingPathExtension().lastPathComponent })
        }
    }

    func testDefaultBrowserSeam() async throws {
        let ls = FakeLaunchServices()
        let seam = ls.seam()
        XCTAssertFalse(seam.isDefault)
        try await seam.makeDefault()
        XCTAssertEqual(ls.calls.map(\.1), ["http"], "macOS changed both with one question")
        XCTAssertEqual(ls.calls.first?.0.lastPathComponent, "iSmith Dev.app")
        XCTAssertTrue(seam.isDefault)
        try await seam.makeDefault()
        XCTAssertEqual(ls.calls.count, 1, "already the default: nothing asked")

        let separate = FakeLaunchServices()
        separate.linksSchemes = false
        try await separate.seam().makeDefault()
        XCTAssertEqual(separate.calls.map(\.1), ["http", "https"])

        let refused = FakeLaunchServices()
        refused.refuse = true
        do {
            try await refused.seam().makeDefault()
            XCTFail("a refusal is an error")
        } catch {}
        XCTAssertEqual(refused.calls.map(\.1), ["http"], "a refusal stops there")
        XCTAssertFalse(refused.seam().isDefault)
    }

    /// The first-run bar is offered once; "Make Default" goes through the seam, "Not Now" too.
    func testFirstRunOfferAndSettingsButton() async throws {
        let ls = FakeLaunchServices()
        let routing = browser.routing
        routing.defaultBrowser = ls.seam()
        routing.offerDefaultBrowserIfNeeded()
        XCTAssertTrue(routing.offersDefaultBrowser)
        XCTAssertFalse(routing.isDefaultBrowser)
        routing.makeDefaultBrowser()
        XCTAssertFalse(routing.offersDefaultBrowser)
        for _ in 0..<100 where !routing.isDefaultBrowser { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(routing.isDefaultBrowser)
        XCTAssertEqual(ls.calls.map(\.1), ["http"])
        XCTAssertTrue(RoutingStore(fileURL: AppPaths(dataDir: dir, spikeDir: nil).routingURL).state.defaultBrowserOffered,
                      "answered: not offered at the next launch")

        // Not Now: not offered again, and LaunchServices isn't touched.
        let other = FakeLaunchServices()
        let fresh = LinkRouter(store: RoutingStore(fileURL: dir.appendingPathComponent("other-routing.json")), defaultBrowser: other.seam())
        fresh.offerDefaultBrowserIfNeeded()
        XCTAssertTrue(fresh.offersDefaultBrowser)
        fresh.declineDefaultBrowser()
        fresh.offerDefaultBrowserIfNeeded()
        XCTAssertFalse(fresh.offersDefaultBrowser)
        XCTAssertTrue(other.calls.isEmpty)

        // A refusal in macOS's question isn't shown as an error; iSmith simply isn't the default.
        let refusing = FakeLaunchServices()
        refusing.refuse = true
        let third = LinkRouter(store: RoutingStore(fileURL: dir.appendingPathComponent("third-routing.json")), defaultBrowser: refusing.seam())
        third.makeDefaultBrowser()
        for _ in 0..<100 where refusing.calls.isEmpty { try await Task.sleep(nanoseconds: 10_000_000) }
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(third.lastError)
        XCTAssertFalse(third.isDefaultBrowser)
    }

    /// The Debug app's Info.plist declares it a browser: http and https, and HTML documents.
    func testInfoPlistDeclaresABrowser() throws {
        let types = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        let schemes = types.flatMap { ($0["CFBundleURLSchemes"] as? [String]) ?? [] }
        XCTAssertEqual(Set(schemes), ["http", "https"])
        let docs = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleDocumentTypes") as? [[String: Any]])
        let contentTypes = docs.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] }
        XCTAssertEqual(Set(contentTypes), ["public.html", "public.xhtml", "com.apple.webarchive"])
        // LaunchServices lists this build for https links (read-only; the default isn't changed).
        let apps = NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://dev.azure.com/contoso-dev")!)
        XCTAssertTrue(apps.contains { Bundle(url: $0)?.bundleIdentifier == Bundle.main.bundleIdentifier },
                      "\(apps.map(\.path))")
    }
}
