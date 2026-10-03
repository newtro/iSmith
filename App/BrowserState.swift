import AppKit
import Combine
import SignInSync
import SwiftUI
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
    let id: String
    @Published var def: SpaceDef
    @Published var tabs: [Tab] = []
    @Published var selectedID: UUID?
    var selected: Tab? { tabs.first { $0.id == selectedID } ?? tabs.last }
    var color: Color { Palette.color(def.color) }

    init(def: SpaceDef) {
        self.def = def
        id = def.id
    }
}

struct EditorRequest: Identifiable {
    let id = UUID()
    /// nil creates a new space.
    let spaceID: String?
}

/// The window's spaces and tabs. Space and account changes go through `SpaceManager`; this layer
/// asks the user first and keeps the tabs in step.
@MainActor
final class BrowserState: NSObject, ObservableObject {
    let config: Config
    let vault: Vault
    let sync: CookieSync
    let manager: SpaceManager
    @Published private(set) var spaces: [SpaceState]
    @Published var activeID: String?
    @Published var showAccounts = true
    @Published var editing: EditorRequest?
    private var opening: Set<String> = []

    /// Safari's user agent, so sites (Google sign-in in particular) treat the app as Safari
    /// rather than an embedded web view.
    static let userAgent: String = {
        let plist = "/Applications/Safari.app/Contents/Info.plist"
        let full = (NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String) ?? "18.0"
        let version = full.split(separator: ".").prefix(2).joined(separator: ".")
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    init(paths: AppPaths = .standard, keyStore: KeyStore = KeychainKeyStore()) {
        var vault = Vault(fileURL: paths.vaultURL, keyStore: keyStore)
        while !vault.canSave {
            // Running on would let the saved vault roll back, on the next launch, any sign-in or
            // sign-out made now, and the spike import would wait. Unlocking the Keychain fixes it.
            let alert = NSAlert()
            alert.messageText = "iSmith can't open its saved sign-ins"
            alert.informativeText = "\(vault.problem ?? "The vault can't be saved.") Unlock the login Keychain or allow iSmith to use it, then try again. Nothing has been changed."
            alert.addButton(withTitle: "Try Again")
            alert.addButton(withTitle: "Quit")
            guard alert.runModal() == .alertFirstButtonReturn else { exit(0) }
            vault = Vault(fileURL: paths.vaultURL, keyStore: keyStore)
        }
        // First launch: the spike's sign-ins come over before config loads, so migration sees them.
        if let spikeDir = paths.spikeDir {
            SpikeImport.runIfNeeded(from: spikeDir, configURL: paths.configURL, vault: vault)
        }
        let config = Config(fileURL: paths.configURL, hasSession: { [vault] in vault.hasSession($0) })
        let sync = CookieSync(vault: vault, config: config)
        self.config = config
        self.vault = vault
        self.sync = sync
        manager = SpaceManager(config: config, vault: vault, sync: sync)
        spaces = config.spaces.map(SpaceState.init)
        activeID = config.spaces.first?.id
        super.init()
        AppDelegate.flush = { [sync] in await sync.flush() }
        sync.bindingChanged = { [weak self] def in
            self?.spaces.first { $0.id == def.id }?.def = def
        }
    }

    var active: SpaceState? { spaces.first { $0.id == activeID } ?? spaces.first }

    func start() {
        if let active { select(active) }
    }

    // MARK: - Spaces

    func select(_ space: SpaceState) {
        activeID = space.id
        // Opening takes a moment; a second click in that window must not open a second home tab.
        if space.tabs.isEmpty, !opening.contains(space.id) {
            opening.insert(space.id)
            Task {
                await newTab(in: space, url: URL(string: space.def.home))
                opening.remove(space.id)
            }
        }
    }

    func select(index: Int) {
        guard spaces.indices.contains(index) else { return }
        select(spaces[index])
    }

    func createSpace(name: String, color: Int, home: String, choices: [String: AccountChoice], newNames: [String: String]) {
        let def = manager.createSpace(name: name, color: color, home: home, choices: choices, newNames: newNames)
        let state = SpaceState(def: def)
        spaces.append(state)
        select(state)
    }

    /// Saves edits. If any account changed, the space's browsing data is cleared (after asking),
    /// every bound account's sign-in is loaded, and its tabs reload as the new accounts.
    func updateSpace(_ id: String, name: String, color: Int, home: String,
                     choices: [String: AccountChoice], newNames: [String: String]) {
        guard let state = spaces.first(where: { $0.id == id }) else { return }
        if !manager.changedProviders(in: id, choices: choices).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Switch accounts in \(state.def.name)?"
            alert.informativeText = "This clears the space's browsing data, including other sites you're signed in to here, and reloads its tabs with the new accounts. Other spaces aren't affected."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var urls: [(Tab, URL?)] = []
        let switching = manager.updateSpace(id, name: name, color: color, home: home, choices: choices, newNames: newNames,
                                            willSwitch: {
            // Pages are parked on a blank page during the switch so a live app (Outlook refreshing
            // a token) can't write the old account back after the wipe.
            urls = state.tabs.map { ($0, $0.webView.url) }
            for (tab, _) in urls { tab.webView.load(URLRequest(url: URL(string: "about:blank")!)) }
        }, committed: { [weak self, weak state] def in
            guard let state, self?.spaces.contains(where: { $0 === state }) == true else { return } // deleted meanwhile
            state.def = def
        })
        guard let switching else { return }
        let parked = urls
        Task {
            await switching.value
            for (tab, url) in parked { if let url { tab.webView.load(URLRequest(url: url)) } }
        }
    }

    func deleteSpace(_ id: String) {
        guard let state = spaces.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(state.def.name)?"
        alert.informativeText = "Closes its tabs and deletes its browsing data. Accounts it uses stay signed in for other spaces."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        for tab in state.tabs { close(tab, in: state) }
        spaces.removeAll { $0.id == id }
        if activeID == id {
            activeID = spaces.first?.id
            if let next = active { select(next) }
        }
        manager.deleteSpace(id)
    }

    // MARK: - Accounts

    func removeAccount(_ id: String) {
        guard config.spaces(using: id).isEmpty else { return }
        if let records = vault.records(for: id), !records.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Remove \(config.account(id).map(config.label) ?? "this account")?"
            alert.informativeText = "Its saved sign-in is deleted. You'd have to sign in again to use it."
            alert.addButton(withTitle: "Remove")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        manager.removeAccount(id)
    }

    func removeProvider(_ id: String) {
        manager.removeProvider(id)
    }

    func signOutEverywhere(_ id: String) {
        Task { await manager.signOutEverywhere(id) }
    }

    // MARK: - Tabs

    func newTabInActive() {
        guard let space = active else { return }
        Task { await newTab(in: space, url: nil) }
    }

    func newTab(in space: SpaceState, url: URL?) async {
        // Seeding must finish before the first request, or the page loads signed out.
        let store = await sync.attach(space.def)
        guard spaces.contains(where: { $0 === space }) else { return } // deleted while opening
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
        guard let space = active, let tab = space.selected else { return }
        close(tab, in: space)
    }

    private func makeWebView(_ config: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.userAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
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
    /// App deep links (msteams:, ms-outlook:) are dropped for now so pages stay in the browser.
    /// P2 opens them in their apps after asking.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased() ?? "about"
        decisionHandler(["http", "https", "about", "data", "blob"].contains(scheme) ? .allow : .cancel)
    }
}
