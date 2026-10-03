import BrowserData
import CryptoKit
import SignInSync
import WebKit
import XCTest
@testable import iSmith

/// P2: back/forward history in the session, the notification shim, app links, downloads and
/// quarantine, permission decisions, the address bar's input rules and the context menu.
@MainActor
final class BrowserBasicsTests: XCTestCase {
    private var server: TestHTTPServer!
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("iSmithP2Tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        server = try TestHTTPServer(routes: [
            "/one": .html("<title>One</title><p>one</p>"),
            "/two": .html("<title>Two</title><p>two</p>"),
            "/three": .html("<title>Three</title><p>three</p>"),
            "/file.bin": .init(type: "application/octet-stream", body: Data(repeating: 7, count: 50_000)),
            "/report": .init(type: "text/plain", headers: ["Content-Disposition": "attachment; filename=\"report.txt\""],
                             body: Data("report".utf8)),
        ])
        try await server.start()
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: dir)
    }

    private func webView(_ configuration: WKWebViewConfiguration = WKWebViewConfiguration()) -> (WKWebView, NavigationWaiter) {
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        return (webView, waiter)
    }

    // MARK: - Session: back/forward history

    /// A tab's history goes through session.json and comes back in a new web view: the same page,
    /// with back and forward working.
    func testBackForwardHistorySurvivesTheSessionFile() async throws {
        let (first, waiter) = webView()
        for path in ["/one", "/two", "/three"] {
            first.load(URLRequest(url: server.url(path)))
            await waiter.next()
        }
        first.goBack()
        await waiter.next()
        XCTAssertEqual(first.url?.path, "/two")
        let state = try XCTUnwrap(first.interactionState as? Data, "interactionState is Data")

        let tab = Tab(id: UUID(), url: first.url, title: "Two")
        tab.savedState = state
        let file = SessionFile(windows: [WindowRecord(id: UUID(), frame: nil, activeSpace: "a", spaces: [
            SpaceRecord(space: "a", selected: tab.id, groups: [], tabs: [tab.record(group: nil)]),
        ])])
        let vaultKey = SymmetricKey(size: .bits256)
        let store = SessionStore(fileURL: dir.appendingPathComponent("session.json"), sealer: HistorySealer(vaultKey: vaultKey))
        store.save(file)
        let bytes = try Data(contentsOf: store.fileURL)
        XCTAssertNil(bytes.range(of: Data(state.base64EncodedString().utf8)), "the history is sealed, not stored as is")
        XCTAssertNil(bytes.range(of: Data("127.0.0.1:\(server.port)/one".utf8)), "nothing of it readable in the file")
        var reader = SessionStore(fileURL: store.fileURL, sealer: HistorySealer(vaultKey: vaultKey))
        let loaded = try XCTUnwrap(reader.load())
        XCTAssertEqual(loaded, file)
        let restoredTab = try XCTUnwrap(SpaceTabs.restore(loaded.windows[0].spaces[0]).ordered.first)
        let history = try XCTUnwrap(restoredTab.savedState)

        let (second, waiter2) = webView()
        second.interactionState = history
        await waiter2.next()
        XCTAssertEqual(second.url?.path, "/two", "the current page comes back")
        XCTAssertEqual(second.backForwardList.backList.map(\.url.path), ["/one"])
        XCTAssertEqual(second.backForwardList.forwardList.map(\.url.path), ["/three"])
        second.goBack()
        await waiter2.next()
        XCTAssertEqual(second.url?.path, "/one")
    }

    /// Unloading a tab (hibernation) keeps its history for the next web view.
    func testUnloadingATabKeepsItsHistory() async throws {
        let (webView, waiter) = webView()
        webView.load(URLRequest(url: server.url("/one")))
        await waiter.next()
        webView.load(URLRequest(url: server.url("/two")))
        await waiter.next()
        let tab = Tab(url: webView.url)
        tab.attach(webView, keepAlive: false)
        tab.unload()
        XCTAssertNil(tab.webView)
        XCTAssertNotNil(tab.savedState)
        XCTAssertEqual(tab.record(group: nil).history, tab.savedState, "the saved session carries it")
    }

    /// Without the key (another Mac, a new vault) histories are dropped and the tabs still open;
    /// without a sealer nothing of the history is written.
    func testHistoryNeedsTheVaultKey() throws {
        let tab = TabRecord(id: UUID(), url: URL(string: "https://example.com"), title: "x", group: nil, keepAlive: nil,
                            history: Data("secret form post".utf8))
        let file = SessionFile(windows: [WindowRecord(id: UUID(), frame: nil, activeSpace: "a", spaces: [
            SpaceRecord(space: "a", selected: tab.id, groups: [], tabs: [tab]),
        ])])
        let url = dir.appendingPathComponent("session.json")
        SessionStore(fileURL: url, sealer: HistorySealer(vaultKey: SymmetricKey(size: .bits256))).save(file)
        var other = SessionStore(fileURL: url, sealer: HistorySealer(vaultKey: SymmetricKey(size: .bits256)))
        let loaded = try XCTUnwrap(other.load())
        XCTAssertNil(loaded.windows[0].spaces[0].tabs[0].history)
        XCTAssertEqual(loaded.windows[0].spaces[0].tabs[0].url, tab.url)

        SessionStore(fileURL: url, sealer: nil).save(file)
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("secret".utf8)))
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("secret form post".utf8).base64EncodedData()))
    }

    func testOversizedOrDamagedHistoryIsDropped() throws {
        let big = TabRecord(id: UUID(), url: nil, title: "", group: nil, keepAlive: nil,
                            history: Data(count: TabRecord.maxHistoryBytes + 1))
        XCTAssertNil(big.history)
        let json = #"{"windows":[{"spaces":[{"space":"a","tabs":[{"url":"https://example.com","history":"%%%not base64"}]}]}]}"#
        let file = try JSONDecoder().decode(SessionFile.self, from: Data(json.utf8))
        XCTAssertNil(file.windows[0].spaces[0].tabs[0].history)
        XCTAssertEqual(file.windows[0].spaces[0].tabs[0].url?.host, "example.com", "the tab survives")
    }

    // MARK: - Notifications

    private final class Recorder: WebNotificationPoster {
        var posted: [WebNotification] = []
        var removed: [String] = []
        var authorizationRequests = 0
        func post(_ notification: WebNotification) { posted.append(notification) }
        func remove(ids: [String]) { removed.append(contentsOf: ids) }
        func requestAuthorization() { authorizationRequests += 1 }
    }

    private func notificationFixture(decisions: [String: Bool] = [:]) -> (WebNotifications, Recorder, WKWebView, NavigationWaiter, UUID, () -> [String: Bool]) {
        let recorder = Recorder()
        var saved = decisions
        let tabID = UUID()
        let shim = WebNotifications(poster: recorder, decision: { saved[$0] }, saveDecision: { saved[$0] = $1 },
                                    context: { _ in (tabID, "Contoso") })
        let configuration = WKWebViewConfiguration()
        shim.install(in: configuration.userContentController)
        shim.install(in: configuration.userContentController) // a popup shares its opener's: no double install
        let (webView, waiter) = webView(configuration)
        return (shim, recorder, webView, waiter, tabID, { saved })
    }

    /// A page creates a Notification; it reaches the app (and macOS) with the site and space, and
    /// the page's click handler runs when the notification is clicked.
    func testPageNotificationReachesTheApp() async throws {
        let (shim, recorder, webView, waiter, tabID, _) = notificationFixture(decisions: [server.origin: true])
        webView.load(URLRequest(url: server.url("/one")))
        await waiter.next()
        _ = try await webView.callAsyncJavaScript("""
            window.events = [];
            await new Promise(r => setTimeout(r, 100));
            const n = new Notification("Build finished", { body: "Storefront #123 passed", tag: "build" });
            n.onshow = () => events.push("show");
            n.onclick = () => events.push("click");
            return Notification.permission;
            """, arguments: [:], in: nil, contentWorld: .page)
        let arrived = await eventually { !recorder.posted.isEmpty }
        XCTAssertTrue(arrived, "the app received the notification")
        let note = try XCTUnwrap(recorder.posted.first)
        XCTAssertEqual(note.title, "Build finished")
        XCTAssertEqual(note.body, "Storefront #123 passed")
        XCTAssertEqual(note.site, "127.0.0.1")
        XCTAssertEqual(note.space, "Contoso")
        XCTAssertEqual(note.tab, tabID)
        XCTAssertEqual(note.id, "Contoso|\(server.origin)#tag:build", "a tag replaces the site's earlier notification in that space")
        let permission = try await webView.evaluateJavaScript("Notification.permission") as? String
        XCTAssertEqual(permission, "granted")

        XCTAssertEqual(shim.clicked(note.id), tabID, "a click focuses the tab")
        let clicked = await eventually {
            ((try? await webView.callAsyncJavaScript("return events.join(',')", contentWorld: .page)) as? String) == "show,click"
        }
        XCTAssertTrue(clicked, "the page saw show, then click")
    }

    /// Without permission, requestPermission asks the app (once), and the answer is saved; the
    /// page world can't reach the native handler itself.
    func testRequestPermissionAsksOnceAndRemembers() async throws {
        let (shim, recorder, webView, waiter, _, saved) = notificationFixture()
        var asked = 0
        shim.ask = { _, host, _, answer in
            asked += 1
            XCTAssertEqual(host, "127.0.0.1")
            answer(.allow)
        }
        webView.load(URLRequest(url: server.url("/one")))
        await waiter.next()
        let result = try await webView.callAsyncJavaScript("return await Notification.requestPermission()", contentWorld: .page)
        XCTAssertEqual(result as? String, "granted")
        XCTAssertEqual(saved()[server.origin], true)
        XCTAssertEqual(recorder.authorizationRequests, 1, "macOS is asked when a site is first allowed")
        let again = try await webView.callAsyncJavaScript("return await Notification.requestPermission()", contentWorld: .page)
        XCTAssertEqual(again as? String, "granted")
        XCTAssertEqual(asked, 1, "a saved answer isn't asked again")
        let handler = try await webView.evaluateJavaScript("typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.ismithNotifications)")
        XCTAssertEqual(handler as? String, "undefined", "the handler lives only in iSmith's content world")
    }

    func testDeniedSiteGetsNoNotifications() async throws {
        let (shim, recorder, webView, waiter, _, _) = notificationFixture(decisions: [server.origin: false])
        defer { withExtendedLifetime(shim) {} }
        webView.load(URLRequest(url: server.url("/one")))
        await waiter.next()
        let result = try await webView.callAsyncJavaScript("""
            await new Promise(r => setTimeout(r, 100));
            const p = await Notification.requestPermission();
            const failed = await new Promise(r => { const n = new Notification("x"); n.onerror = () => r(true); setTimeout(() => r(false), 2000); });
            return p + "/" + failed;
            """, contentWorld: .page)
        XCTAssertEqual(result as? String, "denied/true")
        XCTAssertTrue(recorder.posted.isEmpty)
    }

    // MARK: - App links

    func testAppLinkDecisions() {
        let teams = URL(fileURLWithPath: "/Applications/Microsoft Teams.app")
        let me = URL(fileURLWithPath: "/Applications/iSmith.app")
        let appFor: (URL) -> URL? = { $0.scheme == "msteams" || $0.scheme == "self" ? ($0.scheme == "self" ? me : teams) : nil }
        let link = URL(string: "msteams:/l/chat/0/0")!
        XCTAssertEqual(AppLinks.decide(link, stored: nil, appFor: appFor, ownApp: me), .ask(app: teams, name: "Microsoft Teams"))
        XCTAssertEqual(AppLinks.decide(link, stored: .open, appFor: appFor, ownApp: me), .open(app: teams))
        XCTAssertEqual(AppLinks.decide(link, stored: .block, appFor: appFor, ownApp: me), .block)
        XCTAssertEqual(AppLinks.decide(URL(string: "zoommtg:join")!, stored: nil, appFor: appFor, ownApp: me), .noApp)
        XCTAssertEqual(AppLinks.decide(URL(string: "self:x")!, stored: nil, appFor: appFor, ownApp: me), .noApp,
                       "iSmith never hands a link to itself")
        for web in ["https://teams.microsoft.com", "about:blank", "javascript:alert(1)", "file:///etc/hosts", "data:text/plain,x", "blob:https://a/b"] {
            XCTAssertEqual(AppLinks.decide(URL(string: web)!, stored: .open, appFor: { _ in teams }, ownApp: me), .browser, web)
        }
    }

    /// The answer is remembered per scheme, in the site settings database.
    func testAppLinkAnswerIsRememberedPerScheme() throws {
        let data = try BrowserDatabase.inMemory()
        try data.sites.setAppLinkDecision(.open, scheme: "MSTeams")
        XCTAssertEqual(try data.sites.appLinkDecision(scheme: "msteams"), .open)
        XCTAssertNil(try data.sites.appLinkDecision(scheme: "ms-word"))
        try data.sites.setAppLinkDecision(nil, scheme: "msteams")
        XCTAssertNil(try data.sites.appLinkDecision(scheme: "msteams"))
    }

    // MARK: - Downloads

    func testQuarantineMarksAFile() throws {
        let file = dir.appendingPathComponent("setup.dmg")
        try Data("x".utf8).write(to: file)
        XCTAssertNil(Quarantine.attribute(file))
        try Quarantine.mark(file, source: URL(string: "https://example.com/setup.dmg"), referrer: URL(string: "https://example.com/"))
        let raw = try XCTUnwrap(Quarantine.attribute(file), "com.apple.quarantine is set")
        XCTAssertTrue(raw.hasPrefix("00"), raw)
        let properties = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties ?? [:]
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "iSmith")
        XCTAssertEqual(properties[kLSQuarantineTypeKey as String] as? String, kLSQuarantineTypeWebDownload as String)
    }

    /// A real WKDownload: saved in the downloads folder under a free name, tracked to the end, and
    /// quarantined.
    func testDownloadIsSavedTrackedAndQuarantined() async throws {
        let data = try BrowserDatabase.inMemory()
        let manager = DownloadManager(store: data.downloads)
        manager.folder = dir
        try Data("older".utf8).write(to: dir.appendingPathComponent("file.bin"))
        let (webView, _) = webView()
        let download = await webView.startDownload(using: URLRequest(url: server.url("/file.bin")))
        manager.track(download, space: "contoso", referrer: server.url("/one"))
        let done = await eventually { manager.items.first?.state == .finished }
        XCTAssertTrue(done, "finished: \(String(describing: manager.items.first?.state)) \(manager.items.first?.error ?? "")")
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.fileURL?.lastPathComponent, "file (2).bin", "an existing file isn't replaced")
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(item.fileURL)).count, 50_000)
        XCTAssertNotNil(Quarantine.attribute(try XCTUnwrap(item.fileURL)), "the download is quarantined")
        let saved = try data.downloads.all(limit: 10).first
        XCTAssertEqual(saved?.state, .finished, "the list is saved")
        XCTAssertEqual(saved?.space, "contoso")
    }

    func testDownloadNamesAreSafe() {
        XCTAssertEqual(DownloadManager.safeName("../../etc/passwd"), "-..-etc-passwd")
        XCTAssertEqual(DownloadManager.safeName(".hidden"), "hidden")
        XCTAssertEqual(DownloadManager.safeName("  "), "download")
        XCTAssertEqual(DownloadManager.uniqueURL(in: dir, name: "a.txt").lastPathComponent, "a.txt")
        let long = DownloadManager.safeName(String(repeating: "報告", count: 200) + ".pdf")
        XCTAssertTrue(long.hasSuffix(".pdf"), "the extension survives")
        XCTAssertLessThanOrEqual(long.utf8.count, 240, "fits a file name with room for \" (2)\"")
    }

    // MARK: - Permissions

    func testPermissionDecisionsAreStoredPerSiteAndCombined() throws {
        let data = try BrowserDatabase.inMemory()
        let teams = "https://teams.microsoft.com"
        func decision(_ p: SitePermission, _ origin: String = teams) -> PermissionDecision? {
            SitePermissions.decision(for: p) { try? data.sites.decision($0, origin: origin) }
        }
        XCTAssertNil(decision(.camera))
        try data.sites.setDecision(.allow, for: .cameraAndMicrophone, origin: teams)
        XCTAssertEqual(decision(.camera), .allow, "the pair covers each one")
        XCTAssertEqual(decision(.microphone), .allow)
        XCTAssertNil(decision(.camera, "https://evil.example"), "per site")

        try data.sites.setDecision(nil, for: .cameraAndMicrophone, origin: teams)
        try data.sites.setDecision(.allow, for: .camera, origin: teams)
        XCTAssertNil(decision(.cameraAndMicrophone), "the microphone hasn't been answered")
        try data.sites.setDecision(.allow, for: .microphone, origin: teams)
        XCTAssertEqual(decision(.cameraAndMicrophone), .allow)
        try data.sites.setDecision(.deny, for: .microphone, origin: teams)
        XCTAssertEqual(decision(.cameraAndMicrophone), .deny)
        try data.sites.setDecision(.deny, for: .location, origin: teams)
        XCTAssertEqual(decision(.location), .deny)
        XCTAssertEqual(WKSecurityOrigin.key(scheme: "HTTPS", host: "Teams.Microsoft.com", port: 443), teams)
        XCTAssertEqual(WKSecurityOrigin.key(scheme: "http", host: "localhost", port: 3000), "http://localhost:3000")
    }

    /// The same question twice in a tab is shown once; both callers get the answer.
    func testSitePromptsAreAskedOncePerTab() {
        let browser = BrowserState(paths: AppPaths(dataDir: dir, spikeDir: nil), keyStore: InMemoryKeyStore())
        let tab = Tab(url: nil)
        var answers: [PromptAnswer] = []
        browser.ask(SitePrompt(key: "k", symbol: "bell", message: "m", allowTitle: "Allow") { answers.append($0) }, in: tab)
        browser.ask(SitePrompt(key: "k", symbol: "bell", message: "m", allowTitle: "Allow") { answers.append($0) }, in: tab)
        XCTAssertEqual(tab.prompts.count, 1)
        browser.answer(tab.prompts[0], .allow, in: tab)
        XCTAssertEqual(answers, [.allow, .allow])
        XCTAssertTrue(tab.prompts.isEmpty)
        // A prompt left open when the tab unloads is answered "dismissed" (never remembered).
        browser.ask(SitePrompt(key: "j", symbol: "bell", message: "m", allowTitle: "Allow") { answers.append($0) }, in: tab)
        tab.unload()
        XCTAssertEqual(answers.last, .dismissed)
    }

    // MARK: - Address bar and context menu

    func testHistoryTitlesDropUnreadCounts() {
        XCTAssertEqual(UnreadBadge.stripped("(7) Mail - Scott Smith - Outlook"), "Mail - Scott Smith - Outlook")
        XCTAssertEqual(UnreadBadge.stripped("Report (2) - Google Docs"), "Report (2) - Google Docs")
        XCTAssertEqual(UnreadBadge.stripped("Inbox"), "Inbox")
    }

    func testAddressInputAndSearchEngines() {
        XCTAssertEqual(AddressInput.url(for: "localhost:3000/x", engine: .google)?.absoluteString, "http://localhost:3000/x")
        XCTAssertEqual(AddressInput.url(for: "dev.azure.com/contoso-dev", engine: .google)?.absoluteString, "https://dev.azure.com/contoso-dev")
        XCTAssertEqual(AddressInput.url(for: "intranet:8080", engine: .google)?.absoluteString, "https://intranet:8080")
        XCTAssertEqual(AddressInput.url(for: "app.test", engine: .google)?.absoluteString, "http://app.test")
        XCTAssertEqual(AddressInput.url(for: "what is 2+2", engine: .duckDuckGo)?.absoluteString, "https://duckduckgo.com/?q=what%20is%202+2")
        XCTAssertEqual(AddressInput.url(for: "swift", engine: .kagi)?.host, "kagi.com")
        XCTAssertEqual(AddressInput.url(for: "about:blank", engine: .google)?.absoluteString, "about:blank")
        XCTAssertFalse(AddressInput.looksLikeAddress("v1.2 notes"))
        XCTAssertFalse(AddressInput.looksLikeAddress(".profile"))
    }

    func testContextMenuSwapsWebKitItems() {
        func item(_ title: String, _ id: String) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            i.identifier = NSUserInterfaceItemIdentifier(id)
            return i
        }
        let menu = NSMenu()
        menu.addItem(item("Open Link", "WKMenuItemIdentifierOpenLink"))
        menu.addItem(item("Open Link in New Window", BrowserWebView.Identifier.openLinkInNewWindow))
        menu.addItem(item("Download Linked File", BrowserWebView.Identifier.downloadLinkedFile))
        menu.addItem(item("Copy Link", "WKMenuItemIdentifierCopyLink"))
        menu.addItem(.separator())
        menu.addItem(item("Open Image in New Window", BrowserWebView.Identifier.openImageInNewWindow))
        menu.addItem(item("Download Image", BrowserWebView.Identifier.downloadImage))
        var items = BrowserWebView.ContextMenuItems()
        items.openLink = [NSMenuItem(title: "Open Link in New Tab", action: nil, keyEquivalent: ""),
                          NSMenuItem(title: "Open Link in Space", action: nil, keyEquivalent: "")]
        items.downloadLink = NSMenuItem(title: "Download Linked File (iSmith)", action: nil, keyEquivalent: "")
        items.openImage = NSMenuItem(title: "Open Image in New Tab", action: nil, keyEquivalent: "")
        items.saveImage = NSMenuItem(title: "Save Image As…", action: nil, keyEquivalent: "")
        BrowserWebView.rewrite(menu, with: items)
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title }, [
            "Open Link", "Open Link in New Tab", "Open Link in Space", "Download Linked File (iSmith)", "Copy Link", "-",
            "Open Image in New Tab", "Save Image As…",
        ])
    }
}

