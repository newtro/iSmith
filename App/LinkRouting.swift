import AppKit
import Routing
import SwiftUI
import WebKit

/// P6: links from other apps (Teams, Outlook, Slack) open in the right space. A URL rule picks the
/// space; with none, Outlook, Teams and Gmail links go to the space you last used them in;
/// anything else goes to the Default space. Moving such a tab to another space twice teaches
/// iSmith a rule it offers in a bar. The rules live in `routing.json` (the Routing package).

/// Whether iSmith is the default browser, and making it one. A seam: tests inject fakes, so they
/// never change the Mac's real default browser.
struct DefaultBrowser {
    /// This app's bundle.
    var appURL: URL
    var bundleID: String
    /// The app macOS opens a URL scheme with now.
    var handler: (_ scheme: String) -> URL?
    /// Asks macOS to open a scheme with `app`. macOS asks the user to confirm a browser change.
    var setHandler: (_ app: URL, _ scheme: String) async throws -> Void
    var bundleIDOf: (URL) -> String? = { Bundle(url: $0)?.bundleIdentifier }

    static let schemes = ["http", "https"]

    static var live: DefaultBrowser {
        DefaultBrowser(appURL: Bundle.main.bundleURL, bundleID: AppIdentity.bundleID,
                       handler: { scheme in URL(string: "\(scheme)://example.com").flatMap(NSWorkspace.shared.urlForApplication(toOpen:)) },
                       setHandler: { app, scheme in try await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme) })
    }

    func isDefault(for scheme: String) -> Bool {
        handler(scheme).flatMap(bundleIDOf) == bundleID
    }

    var isDefault: Bool { Self.schemes.allSatisfy(isDefault(for:)) }

    /// http first; macOS shows its one "change your default web browser?" question for it. https
    /// is asked for only if it still isn't iSmith's afterwards. A refusal stops there.
    func makeDefault() async throws {
        for scheme in Self.schemes where !isDefault(for: scheme) {
            try await setHandler(appURL, scheme)
        }
    }
}

/// The app's side of routing: the store, which open tabs came from other apps, the rule on offer
/// and the default-browser state the bars and Settings show.
@MainActor
final class LinkRouter: ObservableObject {
    struct Offer: Equatable {
        var suggestion: RuleSuggestion
        /// The window the move happened in; the bar shows there.
        var window: UUID
    }

    let store: RoutingStore
    var defaultBrowser: DefaultBrowser
    /// Tab id → the address it was opened at from another app. What learning counts when the tab
    /// is moved to another space; forgotten when you type another address in the tab.
    private(set) var incoming: [UUID: URL] = [:]
    @Published var offer: Offer?
    @Published private(set) var isDefaultBrowser = false
    /// The first-run "Make iSmith your default browser" bar.
    @Published private(set) var offersDefaultBrowser = false
    @Published private(set) var lastError: String?

    init(store: RoutingStore, defaultBrowser: DefaultBrowser = .live) {
        self.store = store
        self.defaultBrowser = defaultBrowser
    }

    func linkArrived(_ tab: UUID, url: URL, openTabs: Set<UUID>) {
        incoming = incoming.filter { openTabs.contains($0.key) }
        incoming[tab] = url
    }

    func forget(_ tab: UUID) { incoming[tab] = nil }

    // MARK: Default browser

    /// Re-reads whether iSmith is the default browser (at launch, when Settings opens, when the
    /// app comes forward after macOS's question).
    func refreshDefaultBrowser() {
        let now = defaultBrowser.isDefault
        if isDefaultBrowser != now { isDefaultBrowser = now }
        if now, offersDefaultBrowser { offersDefaultBrowser = false }
    }

    /// At launch: the bar is offered once, until it's answered, if iSmith isn't the default.
    func offerDefaultBrowserIfNeeded() {
        refreshDefaultBrowser()
        offersDefaultBrowser = !isDefaultBrowser && !store.state.defaultBrowserOffered
    }

    func makeDefaultBrowser() {
        store.setDefaultBrowserOffered()
        offersDefaultBrowser = false
        lastError = nil
        Task {
            do {
                try await defaultBrowser.makeDefault()
            } catch {
                // Refused in macOS's question, or LaunchServices failed.
                let code = (error as NSError).code
                if code != NSUserCancelledError { lastError = error.localizedDescription }
            }
            refreshDefaultBrowser()
        }
    }

    func declineDefaultBrowser() {
        store.setDefaultBrowserOffered()
        offersDefaultBrowser = false
    }

    // MARK: Suggestions

    func answer(_ offer: Offer, accept: Bool, never: Bool = false) {
        if accept {
            store.accept(offer.suggestion)
        } else if never {
            store.never(offer.suggestion)
        } else {
            store.postpone(offer.suggestion)
        }
        if self.offer == offer { self.offer = nil }
    }
}

extension AppPaths {
    /// Link rules, the Default space, last-used spaces and learned moves (the Routing package).
    var routingURL: URL { dataDir.appendingPathComponent("routing.json") }
}

extension BrowserState {
    // MARK: - Links from other apps

    /// Opens links handed to the app (`application(_:open:)`): web addresses and HTML files.
    func openIncoming(_ urls: [URL]) {
        for url in urls { openIncoming(url) }
    }

    /// Opens one link in a new tab of the space routing picks, in a window showing that space if
    /// there is one (else the current window, switched to it), and brings that window forward.
    @discardableResult
    func openIncoming(_ url: URL) -> (window: WindowState, tab: Tab)? {
        let scheme = url.scheme?.lowercased()
        guard scheme == "http" || scheme == "https" || url.isFileURL else { return nil }
        let ids = spaces.map(\.id)
        // Files have no host for rules to match: they open in the Default space.
        let target = url.isFileURL ? routing.store.state.effectiveDefaultSpace(in: ids) : routing.store.route(url, spaces: ids)?.space
        guard let target, let space = space(target) else { return nil }
        let window = Self.incomingWindow(for: target, windows: windowsFrontToBack, current: currentWindow) ?? newWindow()
        // The tab is added before the space is shown, so showing an empty space doesn't also open
        // its home page.
        let tab = openTab(in: window, space: target, url: url)
        routing.linkArrived(tab.id, url: url, openTabs: Set(windows.flatMap(\.allTabs).map(\.id)))
        if window.activeSpaceID != target { select(space, in: window) }
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
        return (window, tab)
    }

    /// The window a link for `space` opens in: the current window if it shows that space, else
    /// the frontmost window that does, else the current window. nil when no window is open.
    static func incomingWindow(for space: String, windows: [WindowState], current: WindowState?) -> WindowState? {
        if let current, current.activeSpaceID == space { return current }
        return windows.first { $0.activeSpaceID == space } ?? current ?? windows.first
    }

    /// Browser windows, frontmost first (as listed; windows not on screen keep their order).
    var windowsFrontToBack: [WindowState] {
        let order = NSApp?.orderedWindows ?? []
        func rank(_ w: WindowState) -> Int { w.window.flatMap { order.firstIndex(of: $0) } ?? Int.max }
        return windows.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }.map(\.element)
    }

    // MARK: - Hooks from tab changes

    /// A tab moved to another space (dragged to the rail, "Move to Space", the Dock). Outlook,
    /// Teams and Gmail remember this space; a tab that came from another app counts toward a rule.
    func tabMovedToSpace(_ tab: Tab, space spaceID: String, window: WindowState) {
        if let url = tab.url { routing.store.noteUse(url, space: spaceID) }
        guard let url = routing.incoming[tab.id],
              let suggestion = routing.store.recordMove(link: tab.id, url: url, to: spaceID, spaces: spaces.map(\.id)) else { return }
        routing.offer = LinkRouter.Offer(suggestion: suggestion, window: window.id)
    }

    /// A page committed in a tab: if it's the tab on screen, a shared-address host (Outlook)
    /// remembers this space as last used. Background tabs refreshing themselves don't count.
    func noteVisibleUse(of url: URL, tab: Tab, space spaceID: String) {
        guard let (window, tabs) = owner(of: tab), window.activeSpaceID == spaceID, tabs.layout.selected == tab.id else { return }
        routing.store.noteUse(url, space: spaceID)
    }

    // MARK: - Dock menu

    /// "Open in Space ▸" for the frontmost tab: it moves to that space (reloading as that space's
    /// accounts), and its window switches there.
    func dockMenu() -> NSMenu? {
        guard let window = currentWindow, let tabs = window.active, let tab = tabs.selected, tab.url != nil else { return nil }
        let others = spaces.filter { $0.id != tabs.spaceID }
        guard !others.isEmpty else { return nil }
        let menu = NSMenu()
        let sub = NSMenu()
        let title = NSMenuItem(title: Self.shortTitle(tab.title), action: nil, keyEquivalent: "")
        title.isEnabled = false
        sub.addItem(title)
        sub.addItem(.separator())
        for space in others {
            let item = ActionItem(space.def.name) { [weak self, weak window, weak tab] in
                guard let self, let window, let tab else { return }
                self.moveToSpaceAndShow(tab, in: window, space: space.id)
            }
            item.image = StripContentView.swatch(Palette.nsColor(space.def.color))
            sub.addItem(item)
        }
        let item = NSMenuItem(title: "Open in Space", action: nil, keyEquivalent: "")
        item.submenu = sub
        menu.addItem(item)
        return menu
    }

    /// Moves a tab to another space in its window and shows it there.
    func moveToSpaceAndShow(_ tab: Tab, in window: WindowState, space spaceID: String) {
        guard let (owner, tabs) = owner(of: tab), owner === window, tabs.spaceID != spaceID, let target = space(spaceID) else { return }
        moveTab(tab.id, from: (window, tabs.spaceID), to: (window, spaceID), before: nil, group: nil, select: true)
        select(target, in: window)
        NSApp.activate(ignoringOtherApps: true)
        window.window?.makeKeyAndOrderFront(nil)
    }

    private static func shortTitle(_ title: String) -> String {
        title.count > 48 ? String(title.prefix(47)) + "…" : title
    }

    // MARK: - Loading

    /// Loads a request in a web view. A file (an HTML document opened from Finder) needs read
    /// access granted; its folder is allowed so the page's own images and styles load.
    static func load(_ request: URLRequest, in webView: WKWebView) {
        if let url = request.url, url.isFileURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.load(request)
        }
    }
}

// MARK: - Bars

/// Above the page: the rule iSmith offers after you moved the same kind of link twice, and the
/// first-run "Make iSmith your default browser" offer.
struct RoutingBars: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var routing: LinkRouter
    @ObservedObject var window: WindowState

    var body: some View {
        VStack(spacing: 0) {
            if let offer = routing.offer, offer.window == window.id, let space = browser.space(offer.suggestion.space) {
                bar(symbol: "arrow.triangle.branch",
                    message: "Always open \(offer.suggestion.pattern) in \(space.def.name)?",
                    label: "Link rule suggestion") {
                    Button("Never") { routing.answer(offer, accept: false, never: true) }
                        .help("Don't suggest this rule again")
                    Button("Not Now") { routing.answer(offer, accept: false) }
                    Button("Always Open in \(space.def.name)") { routing.answer(offer, accept: true) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if routing.offersDefaultBrowser {
                bar(symbol: "globe",
                    message: "Make \(AppIdentity.displayName) your default browser? Links from Teams, Outlook and other apps then open here, in the right space.",
                    label: "Default browser") {
                    Button("Not Now") { routing.declineDefaultBrowser() }
                    Button("Make Default") { routing.makeDefaultBrowser() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func bar<Buttons: View>(symbol: String, message: String, label: String, @ViewBuilder buttons: () -> Buttons) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(message).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            buttons()
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
        .padding(.horizontal, 8).padding(.bottom, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(label)
    }
}
