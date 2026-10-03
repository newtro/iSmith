import AppKit
import Combine
import WebKit

@MainActor
final class Tab: ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    @Published var title = "New tab"
    @Published var url: URL?
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    private var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView) {
        self.webView = webView
        observations = [
            webView.observe(\.title) { [weak self] wv, _ in
                Task { @MainActor in self?.title = (wv.title?.isEmpty == false ? wv.title! : (wv.url?.host ?? "New tab")) }
            },
            webView.observe(\.url) { [weak self] wv, _ in
                Task { @MainActor in self?.url = wv.url }
            },
            webView.observe(\.isLoading) { [weak self] wv, _ in
                Task { @MainActor in self?.isLoading = wv.isLoading }
            },
            webView.observe(\.canGoBack) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoBack = wv.canGoBack }
            },
            webView.observe(\.canGoForward) { [weak self] wv, _ in
                Task { @MainActor in self?.canGoForward = wv.canGoForward }
            },
        ]
    }
}

@MainActor
final class SpaceState: ObservableObject, Identifiable {
    let space: Space
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?
    let id: String
    var selected: Tab? { tabs.first { $0.id == selectedID } ?? tabs.last }

    init(space: Space) {
        self.space = space
        id = space.id
    }
}

@MainActor
final class BrowserState: NSObject, ObservableObject {
    let vault: Vault
    let sync: CookieSync
    let spaces: [SpaceState]
    @Published var activeID: String
    @Published var showVault = true
    private var opening: Set<String> = []

    /// Safari's user agent, so sites (Google sign-in in particular) treat the spike as Safari
    /// rather than an embedded web view.
    static let userAgent: String = {
        let plist = "/Applications/Safari.app/Contents/Info.plist"
        let full = (NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String) ?? "18.0"
        let version = full.split(separator: ".").prefix(2).joined(separator: ".")
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    override init() {
        let vault = Vault()
        self.vault = vault
        sync = CookieSync(vault: vault, spaces: Seed.spaces)
        spaces = Seed.spaces.map(SpaceState.init)
        activeID = Seed.spaces[0].id
        super.init()
        AppDelegate.flush = { [sync] in await sync.flush() }
    }

    var active: SpaceState { spaces.first { $0.id == activeID } ?? spaces[0] }

    func start() {
        if Seed.isSelfTest {
            Task { await SelfTest(browser: self).run() }
            return
        }
        select(active)
    }

    func select(_ space: SpaceState) {
        activeID = space.id
        // Attaching takes a moment; a second click in that window must not open a second home tab.
        if space.tabs.isEmpty, !opening.contains(space.id) {
            opening.insert(space.id)
            Task {
                await newTab(in: space, url: space.space.home)
                opening.remove(space.id)
            }
        }
    }

    func select(index: Int) {
        guard spaces.indices.contains(index) else { return }
        select(spaces[index])
    }

    func newTabInActive() {
        let space = active
        Task { await newTab(in: space, url: nil) }
    }

    func newTab(in space: SpaceState, url: URL?) async {
        // Seeding must finish before the first request, or the page loads signed out.
        let store = await sync.attach(space.space)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = store
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let tab = Tab(webView: makeWebView(config))
        space.tabs.append(tab)
        space.selectedID = tab.id
        if let url { tab.webView.load(URLRequest(url: url)) }
    }

    func close(_ tab: Tab, in space: SpaceState) {
        tab.webView.stopLoading()
        tab.webView.removeFromSuperview()
        space.tabs.removeAll { $0.id == tab.id }
        if space.selectedID == tab.id { space.selectedID = space.tabs.last?.id }
    }

    func closeSelectedTab() {
        let space = active
        if let tab = space.selected { close(tab, in: space) }
    }

    private func makeWebView(_ config: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        return webView
    }

    private func owner(of webView: WKWebView) -> (SpaceState, Tab)? {
        for space in spaces {
            if let tab = space.tabs.first(where: { $0.webView === webView }) { return (space, tab) }
        }
        return nil
    }
}

extension BrowserState: WKUIDelegate {
    /// Popups (OAuth windows, target=_blank) open as a tab in the same space. WebKit requires the
    /// returned view to use the configuration it passes, which carries the opener's data store.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let (space, _) = owner(of: webView) else { return nil }
        let tab = Tab(webView: makeWebView(configuration))
        space.tabs.append(tab)
        space.selectedID = tab.id
        return tab.webView
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let (space, tab) = owner(of: webView) else { return }
        close(tab, in: space)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Alert"
        alert.informativeText = message
        alert.runModal()
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert()
        alert.messageText = frame.request.url?.host ?? "Confirm"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        completionHandler(alert.runModal() == .alertFirstButtonReturn)
    }
}

extension BrowserState: WKNavigationDelegate {
    /// App deep links (msteams:, ms-outlook:) are dropped so the spike stays in the browser.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
        decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
    }
}
