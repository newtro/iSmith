import AppKit
import Combine
import SignInSync
import SwiftUI
import WebKit

/// The app's spaces, windows and tabs. Space and account changes go through `SpaceManager`; this
/// layer asks the user first and keeps the tabs in step. Each window shows one space at a time and
/// has its own tabs for every space it has opened.
@MainActor
final class BrowserState: NSObject, ObservableObject {
    let config: Config
    let vault: Vault
    let sync: CookieSync
    let manager: SpaceManager
    @Published private(set) var spaces: [SpaceState]
    @Published private(set) var windows: [WindowState] = []
    /// What's being dragged right now (a tab or a space).
    var drag: DragItem?
    /// Opens an AppKit window for a window state. Unset in tests, which run headless.
    var presentWindow: ((WindowState) -> Void)?
    /// Opens the Settings window (accounts and sign-ins).
    var openSettings: (() -> Void)?
    /// The browser window last made main, for menu commands while another window is key.
    weak var lastActiveWindow: WindowState?
    /// Space id → recently closed tabs, newest last.
    private var closedTabs: [String: [ClosedTab]] = [:]
    private var session: SessionStore
    /// The last window, kept after it closes so quitting that way (or the Dock reopening it)
    /// brings its tabs back.
    private var lastClosedWindow: WindowRecord?
    /// Set when the app starts quitting: the session is saved as it is, and windows closing from
    /// then on don't change it.
    private(set) var quitting = false
    /// Recently closed windows, newest last, with every space's tabs.
    private var closedWindows: [WindowRecord] = []
    /// Space id → its account switch in progress. Web views for that space wait for it, so a page
    /// can't load the old account's cookies and write them back after the wipe.
    private var switching: [String: (token: UUID, task: Task<Void, Never>)] = [:]
    private var refreshScheduled = false
    private var saveTask: Task<Void, Never>?

    /// Safari's user agent, so sites (Google sign-in in particular) treat the app as Safari
    /// rather than an embedded web view.
    static let userAgent: String = {
        let plist = "/Applications/Safari.app/Contents/Info.plist"
        let full = (NSDictionary(contentsOfFile: plist)?["CFBundleShortVersionString"] as? String) ?? "18.0"
        let version = full.split(separator: ".").prefix(2).joined(separator: ".")
        return "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(version) Safari/605.1.15"
    }()

    static let maxClosedTabs = 25
    static let maxClosedWindows = 5

    init(paths: AppPaths = .standard, keyStore: KeyStore = AppIdentity.vaultKeyStore()) {
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
        session = SessionStore(fileURL: paths.sessionURL)
        super.init()
        AppDelegate.flush = { [weak self, sync] in
            self?.quitting = true
            self?.saveSessionNow()
            await sync.flush()
        }
        sync.bindingChanged = { [weak self] def in
            self?.space(def.id)?.def = def
        }
    }

    func space(_ id: String) -> SpaceState? { spaces.first { $0.id == id } }

    /// The window menu commands act on: the key browser window, else the last one made main.
    var currentWindow: WindowState? {
        if let key = NSApp?.keyWindow, let w = windows.first(where: { $0.window === key }) { return w }
        if let w = lastActiveWindow, windows.contains(where: { $0 === w }) { return w }
        return windows.first
    }

    // MARK: - Launch and windows

    /// Restores the saved windows, or opens one on the first space.
    func start() {
        let saved = session.load().map { SessionStore.pruned($0, spaces: Set(config.spaces.map(\.id))) }
        for record in saved?.windows ?? [] { restoreWindow(record) }
        if windows.isEmpty { newWindow() }
        refresh()
    }

    /// ⌘N. With no browser window open, the last closed one comes back instead, so its tabs
    /// aren't replaced in the saved session by an empty window.
    @discardableResult
    func newWindow(space spaceID: String? = nil) -> WindowState {
        if windows.isEmpty, spaceID == nil, let restored = reopenLastWindow() { return restored }
        let id = spaceID ?? currentWindow?.activeSpaceID ?? spaces.first?.id
        let window = WindowState()
        windows.append(window)
        presentWindow?(window)
        if let id, let space = space(id) {
            select(space, in: window)
        }
        scheduleRefresh()
        return window
    }

    @discardableResult
    private func restoreWindow(_ record: WindowRecord) -> WindowState {
        let window = WindowState(id: record.id)
        window.savedFrame = record.frame
        for spaceRecord in record.spaces {
            let tabs = SpaceTabs.restore(spaceRecord)
            hook(tabs)
            window.setTabs(tabs)
        }
        windows.append(window)
        presentWindow?(window)
        if let id = record.activeSpace ?? spaces.first?.id, let space = space(id) { select(space, in: window) }
        // Keep alive tabs load at once, so mail counts update and calls ring.
        for tabs in window.spaces.values {
            for tab in tabs.ordered where tab.keepAlive { ensureLoaded(tab, space: tabs.spaceID) }
        }
        return window
    }

    /// The Dock was clicked with no browser window open: the last closed one comes back.
    func reopen() {
        guard windows.isEmpty else { return }
        if reopenLastWindow() == nil { newWindow() }
        scheduleRefresh()
    }

    /// The window closed last, when it was the only one open; older closed windows are left to
    /// "Reopen Closed Window" and ⌘⇧T. nil (a fresh window) if it had no tabs.
    private func reopenLastWindow() -> WindowState? {
        guard let record = lastClosedWindow else { return nil }
        lastClosedWindow = nil
        if closedWindows.last?.id == record.id { closedWindows.removeLast() }
        guard let pruned = SessionStore.pruned(SessionFile(windows: [record]), spaces: Set(spaces.map(\.id))).windows.first,
              pruned.spaces.contains(where: { !$0.tabs.isEmpty }) else { return nil }
        let window = restoreWindow(pruned)
        scheduleRefresh()
        return window
    }

    /// Brings back the most recently closed window with all its spaces' tabs (⌘⇧T when the
    /// space has no closed tab, "Reopen Closed Window", ⌘N or the Dock with no window open).
    @discardableResult
    func reopenClosedWindow() -> WindowState? {
        let known = Set(spaces.map(\.id))
        while let record = closedWindows.popLast() {
            guard let pruned = SessionStore.pruned(SessionFile(windows: [record]), spaces: known).windows.first else { continue }
            let window = restoreWindow(pruned)
            scheduleRefresh()
            return window
        }
        return nil
    }

    var canReopenClosedWindow: Bool { !closedWindows.isEmpty }

    /// A window is closing: its tabs close with it, and the window is kept so it can be reopened
    /// (with every space's tabs). The last window's tabs are also kept for the next launch, as if
    /// the app had quit.
    func windowWillClose(_ window: WindowState) {
        // AppKit closes every window while quitting; the session saved at quit keeps them all.
        guard !quitting, windows.contains(where: { $0 === window }) else { return }
        let record = window.record(spaceOrder: spaces.map(\.id))
        if !record.spaces.isEmpty {
            closedWindows.append(record)
            if closedWindows.count > Self.maxClosedWindows { closedWindows.removeFirst() }
        }
        if windows.count == 1 { lastClosedWindow = record }
        windows.removeAll { $0 === window }
        for tab in window.allTabs { tab.unload() }
        saveSessionNow()
        scheduleRefresh()
    }

    func windowBecameMain(_ window: WindowState) {
        lastActiveWindow = window
    }

    // MARK: - Spaces

    func select(_ space: SpaceState, in window: WindowState) {
        let tabs = window.tabs(for: space.id)
        hook(tabs)
        window.activeSpaceID = space.id
        if tabs.layout.isEmpty {
            // A space opens on its home page the first time a window shows it (and whenever its
            // last tab there was closed and the space is selected again).
            openTab(in: window, space: space.id, url: URL(string: space.def.home), focusAddress: space.def.home.isEmpty)
        } else if let tab = tabs.selected {
            ensureLoaded(tab, space: space.id)
        }
        scheduleRefresh()
    }

    func select(index: Int, in window: WindowState) {
        guard spaces.indices.contains(index) else { return }
        select(spaces[index], in: window)
    }

    func createSpace(name: String, color: Int, home: String, choices: [String: AccountChoice],
                     newNames: [String: String], in window: WindowState) {
        let def = manager.createSpace(name: name, color: color, home: home, choices: choices, newNames: newNames)
        let state = SpaceState(def: def)
        spaces.append(state)
        select(state, in: window)
    }

    /// Moves a space in the rail; the order is saved in config.
    func moveSpace(_ id: String, to index: Int) {
        config.moveSpace(id, to: index)
        let byID = Dictionary(spaces.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        spaces = config.spaces.compactMap { byID[$0.id] }
        scheduleRefresh()
    }

    /// Every tab a space has, in every window.
    func tabs(inSpace id: String) -> [Tab] {
        windows.compactMap { $0.spaces[id] }.flatMap(\.ordered)
    }

    /// Saves edits. If any account changed, the space's browsing data is cleared (after asking),
    /// every bound account's sign-in is loaded, and its tabs reload as the new accounts.
    func updateSpace(_ id: String, name: String, color: Int, home: String,
                     choices: [String: AccountChoice], newNames: [String: String]) {
        guard let state = space(id) else { return }
        if !manager.changedProviders(in: id, choices: choices).isEmpty {
            let alert = NSAlert()
            alert.messageText = "Switch accounts in \(state.def.name)?"
            alert.informativeText = "This clears the space's browsing data, including other sites you're signed in to here, and reloads its tabs with the new accounts. Other spaces aren't affected."
            alert.addButton(withTitle: "Switch")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        var urls: [(Tab, WKWebView, URL?)] = []
        let switching = manager.updateSpace(id, name: name, color: color, home: home, choices: choices, newNames: newNames,
                                            willSwitch: {
            // Pages are parked on a blank page during the switch so a live app (Outlook refreshing
            // a token) can't write the old account back after the wipe.
            urls = self.tabs(inSpace: id).compactMap { tab in tab.webView.map { (tab, $0, $0.url) } }
            for (_, webView, _) in urls { webView.load(URLRequest(url: URL(string: "about:blank")!)) }
        }, committed: { [weak self, weak state] def in
            guard let state, self?.spaces.contains(where: { $0 === state }) == true else { return } // deleted meanwhile
            state.def = def
        })
        guard let switching else { return }
        // Web views made for this space during the switch wait for this task (see
        // `buildWebView`). It clears its own entry before it finishes, so nobody waiting on it
        // can see the entry still set afterwards.
        let parked = urls
        let token = UUID()
        let done = Task {
            await switching.value
            if self.switching[id]?.token == token { self.switching[id] = nil }
        }
        self.switching[id] = (token, done)
        Task {
            await done.value
            for (tab, webView, url) in parked {
                // Only pages still showing in a tab of this space: one closed, moved or rebuilt
                // meanwhile stays closed.
                guard let url, tab.webView === webView, self.owner(of: tab)?.1.spaceID == id else { continue }
                webView.load(URLRequest(url: url))
            }
        }
    }

    func deleteSpace(_ id: String) {
        guard let state = space(id) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(state.def.name)?"
        alert.informativeText = "Closes its tabs in every window and deletes its browsing data. Accounts it uses stay signed in for other spaces."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        removeSpace(id)
    }

    /// Deletes a space without asking (the editor and the rail ask first).
    func removeSpace(_ id: String) {
        for window in windows {
            for tab in window.spaces[id]?.ordered ?? [] { tab.unload() }
            window.removeSpace(id)
        }
        closedTabs[id] = nil
        spaces.removeAll { $0.id == id }
        for window in windows where window.activeSpaceID == id {
            window.activeSpaceID = nil
            if let next = spaces.first { select(next, in: window) }
        }
        manager.deleteSpace(id)
        scheduleRefresh()
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

    /// Opens a tab in a window's space and selects it. With no URL it's an empty tab, and the
    /// address bar takes focus.
    /// `state` is another web view's `interactionState` (a duplicated tab's history).
    @discardableResult
    func openTab(in window: WindowState, space spaceID: String, url: URL?, title: String? = nil,
                 keepAlive: Bool? = nil, state: Any? = nil, focusAddress: Bool = false,
                 place: ((inout TabLayout, UUID) -> Void)? = nil) -> Tab {
        let tabs = window.tabs(for: spaceID)
        hook(tabs)
        let previous = tabs.selected
        let tab = Tab(url: url, title: title, keepAlive: keepAlive)
        hook(tab)
        tabs.add(tab) { layout in
            if let place { place(&layout, tab.id) } else { layout.insert(tab.id) }
            layout.select(tab.id)
        }
        if let previous { applyKeepAliveIfNeeded(previous, space: spaceID) }
        let request = state == nil ? url.map { URLRequest(url: $0) } : nil
        Task { await buildWebView(for: tab, space: spaceID, state: state, load: request) }
        if focusAddress || (url == nil && state == nil) { window.focusAddress(of: tab.id) }
        scheduleRefresh()
        return tab
    }

    func newTab(in window: WindowState) {
        guard let spaceID = window.activeSpaceID else { return }
        openTab(in: window, space: spaceID, url: nil, focusAddress: true)
    }

    /// Selects a tab and loads it if it isn't yet. A tab that just lost the selection gets the
    /// Keep alive policy its page now calls for (see `applyKeepAliveIfNeeded`).
    func selectTab(_ id: UUID, in tabs: SpaceTabs) {
        let previous = tabs.selected
        tabs.update { $0.select(id) }
        guard let tab = tabs.selected else { return }
        if let previous, previous !== tab { applyKeepAliveIfNeeded(previous, space: tabs.spaceID) }
        ensureLoaded(tab, space: tabs.spaceID)
    }

    func selectNeighbor(forward: Bool, in window: WindowState) {
        guard let tabs = window.active, let current = tabs.layout.selected,
              let next = tabs.layout.neighbor(of: current, forward: forward) else { return }
        selectTab(next, in: tabs)
    }

    /// Creates the tab's web view if it has none, then loads its page.
    func ensureLoaded(_ tab: Tab, space spaceID: String) {
        guard tab.webView == nil, !tab.isBuilding else { return }
        Task { await buildWebView(for: tab, space: spaceID, state: nil, load: tab.url.map { URLRequest(url: $0) }) }
    }

    /// Makes a new web view for a tab in a space's store, with the Keep alive policy the tab calls
    /// for, and shows it in the tab. `state` (a previous web view's `interactionState`) brings back
    /// its back/forward history; `load` is then loaded on top.
    func buildWebView(for tab: Tab, space spaceID: String, state: Any?, load request: URLRequest?) async {
        guard space(spaceID) != nil else { return }
        tab.isBuilding = true
        defer { tab.isBuilding = false }
        // An account switch in this space finishes first, then seeding: a page must never load
        // signed out, or with the account being switched away from.
        await switching[spaceID]?.task.value
        guard let def = space(spaceID)?.def else { return }
        let store = await sync.attach(def)
        // A switch that started while this was waiting for the store parked every page; this one
        // was made after, so it waits too rather than load with the old account.
        if let started = switching[spaceID] { await started.task.value }
        guard owner(of: tab)?.1.spaceID == spaceID else { return } // closed or moved while opening
        let keepAlive = KeepAlive.isOn(setting: tab.keepAliveSetting, url: request?.url ?? tab.url)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        configuration.preferences = Self.preferences(keepAlive: keepAlive)
        let webView = makeWebView(configuration)
        tab.attach(webView, keepAlive: keepAlive)
        #if DEBUG
        NSLog("iSmith: web view for \(request?.url?.host ?? tab.url?.host ?? "empty tab") in \(spaceID), keep alive \(keepAlive)")
        #endif
        if let state { webView.interactionState = state }
        if let request { webView.load(request) }
    }

    /// Each web view gets its own preferences object. WebKit shares a configuration's preferences
    /// with popups it opens, so changing one tab's policy must never touch another's.
    static func preferences(keepAlive: Bool) -> WKPreferences {
        let preferences = WKPreferences()
        preferences.javaScriptCanOpenWindowsAutomatically = true
        // Keep alive: never throttled or suspended in the background, so Teams calls ring and
        // mail counts update.
        preferences.inactiveSchedulingPolicy = keepAlive ? .none : .throttle
        return preferences
    }

    /// Loads what was typed in the address bar. A page that needs a different Keep alive policy
    /// (opening Outlook in an ordinary tab) gets a new web view first, keeping the tab's history.
    func navigate(_ tab: Tab, in tabs: SpaceTabs, to url: URL) {
        let request = URLRequest(url: url)
        let wanted = KeepAlive.isOn(setting: tab.keepAliveSetting, url: url)
        if let webView = tab.webView, tab.appliedKeepAlive == wanted {
            webView.load(request)
        } else {
            let state = tab.webView?.interactionState
            Task { await buildWebView(for: tab, space: tabs.spaceID, state: state, load: request) }
        }
    }

    /// Sets a tab's Keep alive from its context menu. A setting that matches the automatic rule is
    /// stored as "automatic", so the tab keeps following its page. A loaded tab gets a new web view
    /// with the new policy right away, keeping its history.
    func setKeepAlive(_ on: Bool, for tab: Tab, in tabs: SpaceTabs) {
        tab.keepAliveSetting = on == KeepAlive.isAutomatic(tab.url) ? nil : on
        if tab.webView != nil, tab.appliedKeepAlive != tab.keepAlive {
            let state = tab.webView?.interactionState
            Task { await buildWebView(for: tab, space: tabs.spaceID, state: state, load: nil) }
        }
        scheduleRefresh()
    }

    /// A tab whose page now needs Keep alive (it reached Outlook through a form post, which can't
    /// be replayed) gets a new web view once it's in the background. Losing Keep alive waits for
    /// the next time the tab loads, so a page isn't reloaded just to be throttled.
    private func applyKeepAliveIfNeeded(_ tab: Tab, space spaceID: String) {
        guard tab.webView != nil, tab.keepAlive, tab.appliedKeepAlive == false, !tab.isBuilding, !isLinked(tab) else { return }
        let state = tab.webView?.interactionState
        Task { await buildWebView(for: tab, space: spaceID, state: state, load: nil) }
    }

    /// A popup and the tab that opened it, while both are open: replacing either web view would
    /// cut the link between them (a sign-in popup posting its result back).
    private func isLinked(_ tab: Tab) -> Bool {
        let open = windows.flatMap(\.allTabs)
        if let opener = tab.openerID, open.contains(where: { $0.id == opener && $0.webView != nil }) { return true }
        return open.contains { $0.openerID == tab.id && $0.webView != nil }
    }

    func closeTab(_ id: UUID, in tabs: SpaceTabs) {
        guard let tab = tabs.tab(id) else { return }
        // A popup that was showing hands the selection back to the tab that opened it.
        let returnTo = tabs.layout.selected == id ? tab.openerID.flatMap { tabs.layout.contains($0) ? $0 : nil } : nil
        let index = tabs.layout.index(of: id)
        let ids = tabs.layout.ids
        var closed = ClosedTab(url: tab.url, title: tab.title, group: tabs.layout.groupID(of: id),
                               before: index.flatMap { ids.indices.contains($0 + 1) ? ids[$0 + 1] : nil },
                               keepAlive: tab.keepAliveSetting, state: tab.webView?.interactionState)
        if closed.url == nil, closed.state == nil { closed.title = "" } // an empty tab isn't worth reopening
        if !closed.title.isEmpty || closed.url != nil {
            closedTabs[tabs.spaceID, default: []].append(closed)
            if closedTabs[tabs.spaceID]!.count > Self.maxClosedTabs { closedTabs[tabs.spaceID]!.removeFirst() }
        }
        tab.unload()
        tabs.take(id)
        if let returnTo {
            tabs.update { $0.select(returnTo) }
        }
        if let next = tabs.selected { ensureLoaded(next, space: tabs.spaceID) }
        scheduleRefresh()
    }

    func closeTabs(_ ids: [UUID], in tabs: SpaceTabs) {
        for id in ids { closeTab(id, in: tabs) }
    }

    /// ⌘W: closes the selected tab. In an empty space it closes the window, but only when none of
    /// the window's other spaces has tabs, so a second ⌘W can't take a whole window's tabs with it.
    func closeSelectedTab(in window: WindowState) {
        if let tabs = window.active, let id = tabs.layout.selected {
            closeTab(id, in: tabs)
        } else if window.allTabs.isEmpty {
            window.window?.performClose(nil)
        } else {
            NSSound.beep()
        }
    }

    /// ⌘⇧T: reopens the space's most recently closed tab in this window, where it was, with its
    /// history.
    /// With no closed tab in the space, the most recently closed window comes back instead.
    func reopenClosedTab(in window: WindowState) {
        guard let spaceID = window.activeSpaceID, let closed = closedTabs[spaceID]?.popLast() else {
            reopenClosedWindow()
            return
        }
        openTab(in: window, space: spaceID, url: closed.url, title: closed.title, keepAlive: closed.keepAlive,
                state: closed.state) { layout, id in
            let before = closed.before.flatMap { layout.contains($0) ? $0 : nil }
            let group = closed.group.flatMap { layout.group($0) == nil ? nil : $0 }
            layout.insert(id, before: before, group: group)
        }
    }

    func duplicate(_ id: UUID, in tabs: SpaceTabs, window: WindowState) {
        guard let tab = tabs.tab(id) else { return }
        openTab(in: window, space: tabs.spaceID, url: tab.url, title: tab.title, keepAlive: tab.keepAliveSetting,
                state: tab.webView?.interactionState) { layout, new in
            layout.insert(new, after: id)
        }
    }

    /// "New Tab to the Right" from a tab's context menu: joins that tab's group.
    func newTab(after id: UUID, in tabs: SpaceTabs, window: WindowState) {
        openTab(in: window, space: tabs.spaceID, url: nil, focusAddress: true) { layout, new in
            layout.insert(new, after: id)
        }
    }

    /// "New Tab in Group" from a group label.
    func newTab(inGroup group: UUID, tabs: SpaceTabs, window: WindowState) {
        openTab(in: window, space: tabs.spaceID, url: nil, focusAddress: true) { layout, new in
            layout.insert(new, group: group)
        }
    }

    func reload(_ tab: Tab, in tabs: SpaceTabs) {
        if let webView = tab.webView { webView.reload() } else { ensureLoaded(tab, space: tabs.spaceID) }
    }

    // MARK: - Moving tabs

    /// Moves a tab to a place in a window's space. Within one space the tab moves as it is; into
    /// another space it reloads there, under that space's sign-ins.
    func moveTab(_ id: UUID, from source: (window: WindowState, space: String),
                 to target: (window: WindowState, space: String), before: UUID?, group: UUID?, select: Bool = true) {
        guard let sourceTabs = source.window.spaces[source.space], let tab = sourceTabs.tab(id) else { return }
        if source.window === target.window, source.space == target.space {
            sourceTabs.update { $0.move(id, before: before, group: group) }
            return
        }
        let targetTabs = target.window.tabs(for: target.space)
        hook(targetTabs)
        let sameSpace = source.space == target.space
        // A tab leaving its space closes its web view: the target space's store loads it again.
        let state = sameSpace ? nil : tab.webView?.interactionState
        if !sameSpace { tab.unload() }
        sourceTabs.take(id)
        if let next = sourceTabs.selected, source.window.activeSpaceID == source.space { ensureLoaded(next, space: source.space) }
        targetTabs.add(tab) { $0.insert(id, before: before, group: group) }
        let visible = target.window.activeSpaceID == target.space
        if select || targetTabs.layout.selected == nil { targetTabs.update { $0.select(id) } }
        if !sameSpace {
            // Back/forward history comes along; the page itself reloads in the new space's store.
            Task { await buildWebView(for: tab, space: target.space, state: state, load: state == nil ? tab.url.map { URLRequest(url: $0) } : nil) }
        } else if visible, targetTabs.layout.selected == id {
            ensureLoaded(tab, space: target.space)
        }
        scheduleRefresh()
    }

    /// Moves tabs to another space in the same window (dragged onto the rail, or "Move to Space").
    /// They go to the end of that space's strip and reload signed in as that space.
    func moveTabs(_ ids: [UUID], from tabs: SpaceTabs, in window: WindowState, toSpace spaceID: String) {
        guard spaceID != tabs.spaceID, space(spaceID) != nil else { return }
        for id in ids {
            moveTab(id, from: (window, tabs.spaceID), to: (window, spaceID), before: nil, group: nil, select: false)
        }
    }

    /// Moves a tab into a new window showing the same space, optionally at a screen point (a tab
    /// dragged out of the strip).
    func moveToNewWindow(_ id: UUID, from tabs: SpaceTabs, in window: WindowState, at point: NSPoint? = nil) {
        guard tabs.tab(id) != nil else { return }
        let created = WindowState(activeSpaceID: tabs.spaceID)
        if let frame = window.window?.frame {
            let origin = point.map { NSPoint(x: $0.x - 120, y: $0.y - frame.height + 20) }
                ?? NSPoint(x: frame.minX + 30, y: frame.minY - 30)
            created.initialFrame = NSRect(origin: origin, size: frame.size)
        }
        windows.append(created)
        let target = created.tabs(for: tabs.spaceID)
        hook(target)
        moveTab(id, from: (window, tabs.spaceID), to: (created, tabs.spaceID), before: nil, group: nil)
        presentWindow?(created)
        if let space = space(tabs.spaceID) { select(space, in: created) }
        // The source space may be empty now; it shows its empty state until a new tab is opened.
        scheduleRefresh()
    }

    // MARK: - Groups

    @discardableResult
    func createGroup(with ids: [UUID], in tabs: SpaceTabs) -> UUID? {
        var created: UUID?
        tabs.update { created = $0.createGroup(with: ids) }
        tabs.marked = []
        return created
    }

    func toggleCollapsed(_ group: UUID, in tabs: SpaceTabs, window: WindowState) {
        guard let g = tabs.layout.group(group) else { return }
        var ok = true
        tabs.update { ok = $0.setCollapsed(group, !g.collapsed) }
        if !ok {
            // Every tab is in this group: open a new one so something stays selected, then collapse.
            openTab(in: window, space: tabs.spaceID, url: nil, focusAddress: true)
            tabs.update { $0.setCollapsed(group, true) }
        }
        if let selected = tabs.selected { ensureLoaded(selected, space: tabs.spaceID) }
    }

    func closeGroup(_ group: UUID, in tabs: SpaceTabs) {
        closeTabs(tabs.layout.tabs(in: group), in: tabs)
    }

    // MARK: - Badges and saving

    /// Hooks a space's tabs to the badges and the saved session.
    private func hook(_ tabs: SpaceTabs) {
        tabs.changed = { [weak self] in self?.scheduleRefresh() }
        for tab in tabs.ordered { hook(tab) }
    }

    private func hook(_ tab: Tab) {
        tab.changed = { [weak self] in self?.scheduleRefresh() }
    }

    /// Badges update on the next turn of the run loop; the session is saved a second later, so a
    /// burst of title changes writes the file once.
    func scheduleRefresh() {
        if !refreshScheduled {
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
        // A save already waiting covers this change too. It isn't pushed back, so a page that
        // changes its title every second (Teams flashing a message) can't keep the session unsaved.
        guard saveTask == nil else { return }
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveSessionNow()
        }
    }

    private func refresh() {
        for space in spaces {
            let total = UnreadBadge.total(tabs(inSpace: space.id).map(\.title))
            if space.unread != total { space.unread = total }
        }
    }

    var sessionSnapshot: SessionFile {
        let order = spaces.map(\.id)
        let records = windows.map { $0.record(spaceOrder: order) }
        return SessionFile(windows: records.isEmpty ? lastClosedWindow.map { [$0] } ?? [] : records)
    }

    func saveSessionNow() {
        saveTask?.cancel()
        saveTask = nil
        session.save(sessionSnapshot)
    }

    // MARK: - Web views

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

    /// The window, space tabs and tab a web view belongs to.
    func owner(of webView: WKWebView) -> (WindowState, SpaceTabs, Tab)? {
        for window in windows {
            for tabs in window.spaces.values {
                if let tab = tabs.ordered.first(where: { $0.webView === webView }) { return (window, tabs, tab) }
            }
        }
        return nil
    }

    func owner(of tab: Tab) -> (WindowState, SpaceTabs)? {
        for window in windows {
            for tabs in window.spaces.values where tabs.tab(tab.id) === tab { return (window, tabs) }
        }
        return nil
    }
}

extension BrowserState: WKUIDelegate {
    /// Popups (OAuth windows, target=_blank) open as a tab next to their opener, in its group and
    /// space. WebKit requires the returned view to use the configuration it passes, which carries
    /// the opener's data store; it gets its own preferences so its Keep alive is its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let (window, tabs, opener) = owner(of: webView) else { return nil }
        let keepAlive = KeepAlive.isAutomatic(navigationAction.request.url)
        configuration.preferences = Self.preferences(keepAlive: keepAlive)
        let tab = Tab(url: navigationAction.request.url)
        tab.openerID = opener.id
        hook(tab)
        let popup = makeWebView(configuration)
        tab.attach(popup, keepAlive: keepAlive)
        tabs.add(tab) { $0.insert(tab.id, after: opener.id) }
        if window.activeSpaceID == tabs.spaceID { selectTab(tab.id, in: tabs) }
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let (_, tabs, tab) = owner(of: webView) else { return }
        closeTab(tab.id, in: tabs)
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
    /// App deep links (msteams:, ms-outlook:) are dropped for now so pages stay in the browser;
    /// P2 opens them in their apps after asking.
    ///
    /// A tab following a link or redirect to a Keep alive page (Outlook, Teams, Gmail) gets a new
    /// web view with that policy, which loads the same request; WebKit reads the policy only when a
    /// web view is created. Form posts can't be replayed safely, so they go ahead and the policy
    /// follows once the tab is in the background.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? "about"
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else { return decisionHandler(.cancel) }
        if navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType != .backForward,
           (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
           let (_, tabs, tab) = owner(of: webView),
           tab.appliedKeepAlive == false, !tab.isBuilding, !isLinked(tab),
           KeepAlive.isOn(setting: tab.keepAliveSetting, url: url) {
            decisionHandler(.cancel)
            let state = webView.interactionState
            let request = navigationAction.request
            Task { await buildWebView(for: tab, space: tabs.spaceID, state: state, load: request) }
            return
        }
        decisionHandler(.allow)
    }
}
