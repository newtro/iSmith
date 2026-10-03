import AppKit
import Combine
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

/// The account a space uses for one provider, as picked in the space editor or a sign-in banner.
enum AccountChoice: Hashable {
    case none
    case existing(String)
    case new
}

struct EditorRequest: Identifiable {
    let id = UUID()
    /// nil creates a new space.
    let spaceID: String?
}

@MainActor
final class BrowserState: NSObject, ObservableObject {
    let config: Config
    let vault: Vault
    let sync: CookieSync
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

    override init() {
        let config = Config()
        let vault = Vault()
        self.config = config
        self.vault = vault
        sync = CookieSync(vault: vault, config: config)
        spaces = config.spaces.map(SpaceState.init)
        activeID = config.spaces.first?.id
        super.init()
        AppDelegate.flush = { [sync] in await sync.flush() }
    }

    var active: SpaceState? { spaces.first { $0.id == activeID } ?? spaces.first }

    func start() {
        if AppPaths.isSelfTest {
            Task { await SelfTest(browser: self).run() }
            return
        }
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
        let def = SpaceDef(id: "space-" + UUID().uuidString.prefix(8).lowercased(), name: name, color: color,
                           storeID: UUID(), bindings: resolve(choices, newNames, spaceName: name), home: home)
        config.upsert(def)
        let state = SpaceState(def: def)
        spaces.append(state)
        select(state)
    }

    /// Saves edits. If any account changed, the space's browsing data is cleared (after asking),
    /// every bound account's sign-in is loaded, and its tabs reload as the new accounts.
    func updateSpace(_ id: String, name: String, color: Int, home: String,
                     choices: [String: AccountChoice], newNames: [String: String], confirm: Bool = true) {
        guard let state = spaces.first(where: { $0.id == id }) else { return }
        let old = state.def
        let wanted = choices.filter { $0.value != .none }
        let changed = Set(old.bindings.keys).union(wanted.keys).filter { provider in
            switch wanted[provider] {
            case .existing(let accountID): return old.bindings[provider] != accountID
            case .new: return true
            default: return old.bindings[provider] != nil
            }
        }
        if !changed.isEmpty && confirm {
            let alert = NSAlert()
            alert.messageText = "Switch accounts in \(old.name)?"
            alert.informativeText = "This clears the space's browsing data, including other sites you're signed in to here, and reloads its tabs with the new accounts. Other spaces aren't affected."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var def = old
        def.name = name
        def.color = color
        def.home = home
        guard !changed.isEmpty else {
            config.upsert(def)
            state.def = def
            return
        }
        def.bindings = resolve(choices, newNames, spaceName: name)
        let oldAccounts = changed.compactMap { old.bindings[$0] }
        Task {
            await sync.switchAccounts(spaceID: id, oldAccounts: oldAccounts) { [config] in
                config.upsert(def)
                state.def = def
            }
            for tab in state.tabs { tab.webView.reload() }
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
        config.removeSpace(id)
        let storeID = state.def.storeID
        Task {
            await sync.detach(id)
            do { try await WKWebsiteDataStore.remove(forIdentifier: storeID) } catch { NSLog("iSmith: store removal failed: \(error)") }
        }
    }

    /// "Save this sign-in" from the banner: the space now uses `choice` for the provider, and its
    /// current sign-in becomes that account's.
    func saveDetected(spaceID: String, providerID: String, choice: AccountChoice, newName: String) {
        guard let state = spaces.first(where: { $0.id == spaceID }), state.def.bindings[providerID] == nil,
              sync.detected[spaceID]?.contains(providerID) == true else { return }
        // Hidden right away, so a second click can't create a second account.
        sync.dismissDetected(spaceID: spaceID, providerID: providerID)
        let accountID: String
        switch choice {
        case .none: return
        case .existing(let id): accountID = id
        case .new: accountID = config.addAccount(providerID: providerID, name: newName.isEmpty ? state.def.name : newName).id
        }
        Task {
            await sync.adoptSignIn(spaceID: spaceID, providerID: providerID) { [config] in
                state.def.bindings[providerID] = accountID
                config.upsert(state.def)
            }
        }
    }

    func keepLocal(spaceID: String, providerID: String) {
        guard let state = spaces.first(where: { $0.id == spaceID }) else { return }
        if !state.def.localProviders.contains(providerID) { state.def.localProviders.append(providerID) }
        config.upsert(state.def)
        sync.dismissDetected(spaceID: spaceID, providerID: providerID)
    }

    private func resolve(_ choices: [String: AccountChoice], _ newNames: [String: String], spaceName: String) -> [String: String] {
        var bindings: [String: String] = [:]
        for (providerID, choice) in choices {
            switch choice {
            case .none: break
            case .existing(let id): bindings[providerID] = id
            case .new:
                let name = newNames[providerID].flatMap { $0.isEmpty ? nil : $0 } ?? spaceName
                bindings[providerID] = config.addAccount(providerID: providerID, name: name).id
            }
        }
        return bindings
    }

    // MARK: - Accounts

    func removeAccount(_ id: String) {
        guard config.spaces(using: id).isEmpty else { return }
        config.removeAccount(id)
        vault.remove(id)
    }

    func signOutEverywhere(_ id: String) {
        Task { await sync.signOutEverywhere(id) }
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
