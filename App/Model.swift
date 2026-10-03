import AppKit
import Combine
import SignInSync
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// One tab. Its web view is created when the tab is first shown (or at once, for a Keep alive
/// tab), so a restored tab costs nothing until it's selected.
@MainActor
final class Tab: ObservableObject, Identifiable {
    let id: UUID
    @Published private(set) var webView: WKWebView?
    @Published private(set) var title: String
    /// The page's URL, or the one it will load when it's first shown.
    @Published private(set) var url: URL?
    @Published private(set) var isLoading = false
    @Published private(set) var canGoBack = false
    @Published private(set) var canGoForward = false
    /// The tab's own Keep alive setting; nil follows the automatic rule (Outlook, Teams, Gmail).
    @Published var keepAliveSetting: Bool?
    /// Keep alive was turned off by link routing (a second Outlook in a space that already keeps
    /// one alive), not by you: it isn't saved, and it's undone when the tab moves or the kept-alive
    /// one closes.
    var keepAliveLowered = false
    /// The policy the current web view was created with. WebKit reads
    /// `inactiveSchedulingPolicy` when a web view is created, so changing it means a new web view.
    private(set) var appliedKeepAlive: Bool?
    /// A web view is being made for the tab (opening a space's store takes a moment).
    var isBuilding = false
    /// The tab whose page opened this one (a popup). Neither web view is replaced automatically
    /// while both are open, since they may still talk to each other (sign-in popups do), and
    /// closing the popup goes back to its opener.
    var openerID: UUID?
    /// Called when the URL changes: badges and the saved session follow.
    var changed: (() -> Void)?
    /// Called when only the title changes (saved a little later).
    var titleChanged: (() -> Void)?
    /// The title history last got for this page.
    var lastHistoryTitle: String?
    /// The live web view's history, read again only after it navigates.
    private var cachedHistory: Data?
    private var historyStale = true
    /// The back/forward history while the tab has no web view (restored from the session, or
    /// hibernated). The next web view starts from it.
    var savedState: Data?
    /// The page's web content process died; the tab shows a reload state (see `crash`).
    @Published var crashed = false
    /// Recent crashes, so a page that keeps crashing isn't reloaded forever.
    var crashTimes: [Date] = []
    /// Questions from the page shown as a bar over it (permissions, app links), oldest first.
    @Published var prompts: [SitePrompt] = []
    /// JavaScript alerts, confirms and prompts and sign-in sheets waiting for the tab to be shown.
    var pendingDialogs: [PendingDialog] = []
    /// One of the tab's dialogs is on screen.
    var showingDialog = false
    /// How the main frame's current navigation started (history skips back/forward and reloads).
    var lastNavigationType: WKNavigationType?
    /// What was last typed in the address bar and when, so the visit counts as typed in history.
    var typed: (url: URL, at: Date)?
    /// Called when the page changes its title (history keeps titles), and when it changes its
    /// address without loading (a single-page app moving on, which history records too).
    var retitled: ((String) -> Void)?
    var movedInPage: ((URL) -> Void)?
    /// A certificate problem stopped the last navigation; the tab shows a warning page.
    @Published var certificateProblem: CertificateProblem?
    /// Find in page (⌘F).
    @Published var findShown = false
    @Published var findText = ""
    @Published var findResult: Bool?
    /// The page zoom (⌘+ / ⌘−), remembered per site.
    @Published var zoom: CGFloat = 1
    /// When the tab was last on screen, for hibernation.
    var lastShown = Date()
    let createdAt = Date()
    /// A load that failed in the background (no network): tried again later.
    var retryURL: URL?
    private var observations: [NSKeyValueObservation] = []

    init(id: UUID = UUID(), url: URL?, title: String? = nil, keepAlive: Bool? = nil, history: Data? = nil) {
        self.id = id
        self.url = url
        self.title = title.flatMap { $0.isEmpty ? nil : $0 } ?? url?.host ?? "New tab"
        keepAliveSetting = keepAlive
        savedState = history
    }

    /// The tab's back/forward history: the live web view's, or the one saved for it. The live
    /// one is read again only after a navigation, not on every save.
    var history: Data? {
        guard let webView else { return savedState }
        if historyStale || cachedHistory == nil {
            cachedHistory = webView.interactionState as? Data
            historyStale = false
        }
        return cachedHistory ?? savedState
    }

    /// Whether the tab is kept alive: its own setting, or the automatic rule for its page.
    var keepAlive: Bool { KeepAlive.isOn(setting: keepAliveSetting, url: url) }
    var unread: Int? { UnreadBadge.count(in: title) }

    /// Shows a new web view in the tab, replacing (and closing) any old one.
    func attach(_ webView: WKWebView, keepAlive: Bool) {
        let old = detachWebView()
        old.map(Self.close)
        self.webView = webView
        appliedKeepAlive = keepAlive
        cachedHistory = nil
        historyStale = true
        savedState = nil
        crashed = false
        certificateProblem = nil
        observations = [
            webView.observe(\.title, options: [.initial]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, self.webView === wv else { return }
                    if let t = wv.title, !t.isEmpty {
                        self.title = t
                        self.retitled?(t)
                    } else if let host = wv.url?.host {
                        self.title = host
                    }
                    self.titleChanged?()
                }
            },
            webView.observe(\.url, options: [.initial]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, self.webView === wv, let url = wv.url else { return }
                    let moved = self.url != url && !wv.isLoading
                    self.url = url
                    self.historyStale = true
                    if moved { self.movedInPage?(url) }
                    self.changed?()
                }
            },
            webView.observe(\.isLoading, options: [.initial]) { [weak self] wv, _ in
                MainActor.assumeIsolated {
                    guard let self, self.webView === wv else { return }
                    self.isLoading = wv.isLoading
                    if !wv.isLoading {
                        self.historyStale = true
                        self.changed?()
                    }
                }
            },
            webView.observe(\.canGoBack, options: [.initial]) { [weak self] wv, _ in
                MainActor.assumeIsolated { if let self, self.webView === wv { self.canGoBack = wv.canGoBack } }
            },
            webView.observe(\.canGoForward, options: [.initial]) { [weak self] wv, _ in
                MainActor.assumeIsolated { if let self, self.webView === wv { self.canGoForward = wv.canGoForward } }
            },
        ]
    }

    /// Closes the web view; the tab keeps its title, URL and history and loads again when shown.
    func unload() {
        historyStale = true
        if let state = history { savedState = state }
        detachWebView().map(Self.close)
    }

    private func detachWebView() -> WKWebView? {
        observations.forEach { $0.invalidate() }
        observations = []
        // What the old page was waiting on is answered "no": WebKit needs every handler called.
        let dialogs = pendingDialogs
        pendingDialogs = []
        dialogs.forEach { $0.cancel() }
        let questions = prompts
        prompts = []
        questions.forEach { $0.answer(.dismissed) }
        let old = webView
        webView = nil
        appliedKeepAlive = nil
        isLoading = false
        return old
    }

    private static func close(_ webView: WKWebView) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// The tab as saved in session.json.
    func record(group: UUID?) -> TabRecord {
        TabRecord(id: id, url: url, title: title, group: group, keepAlive: keepAliveLowered ? nil : keepAliveSetting, history: history)
    }
}

/// One space's tabs in one window: the tabs themselves and their layout (order, groups, selection).
@MainActor
final class SpaceTabs: ObservableObject {
    let spaceID: String
    @Published private(set) var layout = TabLayout()
    /// Tabs picked with ⌘-click or ⇧-click, for grouping or closing several at once. Not saved.
    @Published var marked: Set<UUID> = []
    private(set) var tabs: [UUID: Tab] = [:]
    /// Called after any change to the layout.
    var changed: (() -> Void)?

    init(spaceID: String) {
        self.spaceID = spaceID
    }

    var selected: Tab? { layout.selected.flatMap { tabs[$0] } }
    var ordered: [Tab] { layout.ids.compactMap { tabs[$0] } }
    func tab(_ id: UUID) -> Tab? { tabs[id] }

    /// The tabs an action from `id`'s context menu applies to: the marked tabs if `id` is one of
    /// them, otherwise `id` alone.
    func targets(for id: UUID) -> [UUID] {
        guard marked.contains(id) else { return [id] }
        return layout.ids.filter { marked.contains($0) || $0 == layout.selected }
    }

    func update(_ change: (inout TabLayout) -> Void) {
        change(&layout)
        marked.formIntersection(layout.ids)
        changed?()
    }

    func add(_ tab: Tab, place: (inout TabLayout) -> Void) {
        tabs[tab.id] = tab
        update(place)
        if !layout.contains(tab.id) { update { $0.insert(tab.id) } }
    }

    /// Takes a tab out of the space (to close it or move it elsewhere).
    @discardableResult
    func take(_ id: UUID) -> Tab? {
        let tab = tabs.removeValue(forKey: id)
        update { $0.remove(id) }
        return tab
    }

    var record: SpaceRecord {
        SpaceRecord(space: spaceID, selected: layout.selected, groups: layout.groups,
                    tabs: layout.ids.compactMap { id in tabs[id]?.record(group: layout.groupID(of: id)) })
    }

    /// Rebuilds the space's tabs from a saved record; none of them are loaded yet.
    static func restore(_ record: SpaceRecord) -> SpaceTabs {
        let state = SpaceTabs(spaceID: record.space)
        let byID = Dictionary(record.tabs.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        state.layout = record.layout
        for id in state.layout.ids {
            guard let r = byID[id] else { continue }
            state.tabs[id] = Tab(id: id, url: r.url, title: r.title, keepAlive: r.keepAlive, history: r.history)
        }
        return state
    }
}

/// A browser window: which space it shows, and its own tabs for each space it has opened.
@MainActor
final class WindowState: ObservableObject, Identifiable {
    let id: UUID
    @Published var activeSpaceID: String?
    @Published private(set) var spaces: [String: SpaceTabs] = [:]
    @Published var editing: EditorRequest?
    /// Asks the toolbar to focus the address bar: nil for the current tab (⌘L), or a tab's id.
    let focusRequests = PassthroughSubject<UUID?, Never>()
    /// A new tab whose address bar takes focus once its toolbar is on screen. The toolbar for a
    /// tab that was just created doesn't exist yet when the request is sent.
    var pendingAddressFocus: UUID?
    /// The downloads panel is open.
    @Published var downloadsShown = false
    /// Asks the find bar to take focus (⌘F).
    let findFocusRequests = PassthroughSubject<Void, Never>()
    /// Asks the toolbar to bookmark the page and show its editor (⌘D).
    let bookmarkRequests = PassthroughSubject<Void, Never>()

    /// Focuses the address bar of `tab` (default: whichever tab is showing).
    func focusAddress(of tab: UUID? = nil) {
        pendingAddressFocus = tab
        focusRequests.send(tab)
    }
    weak var window: NSWindow?
    /// The frame to open at, from the saved session.
    var savedFrame: String?
    /// The frame to open at for a window made from a dragged tab.
    var initialFrame: NSRect?

    init(id: UUID = UUID(), activeSpaceID: String? = nil) {
        self.id = id
        self.activeSpaceID = activeSpaceID
    }

    var active: SpaceTabs? { activeSpaceID.flatMap { spaces[$0] } }
    var allTabs: [Tab] { spaces.values.flatMap(\.ordered) }

    /// The window's tabs for a space, created empty the first time.
    func tabs(for spaceID: String) -> SpaceTabs {
        if let existing = spaces[spaceID] { return existing }
        let created = SpaceTabs(spaceID: spaceID)
        spaces[spaceID] = created
        return created
    }

    func setTabs(_ tabs: SpaceTabs) { spaces[tabs.spaceID] = tabs }
    func removeSpace(_ id: String) { spaces[id] = nil }

    func record(spaceOrder: [String]) -> WindowRecord {
        WindowRecord(id: id, frame: window?.frameDescriptor ?? savedFrame, activeSpace: activeSpaceID,
                     spaces: spaceOrder.compactMap { spaces[$0] }.filter { !$0.layout.isEmpty }.map(\.record))
    }
}

/// A space as the rail shows it: its definition and its unread count across every window.
@MainActor
final class SpaceState: ObservableObject, Identifiable {
    let id: String
    @Published var def: SpaceDef
    @Published var unread = 0
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

/// What's being dragged. Drags carry only an id on the pasteboard; drop targets read this to
/// find the tab or space, so nothing from outside the app can be dropped as one.
enum DragItem: Equatable {
    case tab(UUID, window: UUID, space: String)
    case space(String)
}

/// A closed tab, for ⌘⇧T. Its back/forward history comes back too.
struct ClosedTab {
    var url: URL?
    var title: String
    var group: UUID?
    /// The tab that followed it, so it reopens in the same place.
    var before: UUID?
    var keepAlive: Bool?
    var state: Any?
}

extension UTType {
    /// A tab being dragged within iSmith (declared in Info.plist).
    /// Named after the bundle id, so the Debug and installed apps never take each other's drags.
    static let ismithTab = UTType(exportedAs: AppIdentity.bundleID + ".tab")
    /// A space being dragged in the rail.
    static let ismithSpace = UTType(exportedAs: AppIdentity.bundleID + ".space")
}

extension NSPasteboard.PasteboardType {
    static let ismithTab = NSPasteboard.PasteboardType(UTType.ismithTab.identifier)
}
