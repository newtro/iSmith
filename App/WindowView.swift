import AppKit
import BrowserData
import Combine
import SignInSync
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A browser window: the space rail on the left, then the current space's tab strip, toolbar and
/// page. The chrome right of the rail is tinted with the space's color and fades to the new color
/// when you switch spaces.
struct BrowserWindowView: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState

    var body: some View {
        HStack(spacing: 0) {
            Rail(window: window)
            Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
            content
                .background(tint)
                .sheet(isPresented: $window.overviewShown) {
                    if let space = activeSpace, let tabs = window.spaces[space.id] {
                        TabOverview(window: window, tabs: tabs, spaceName: space.def.name)
                    }
                }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
        .frame(minWidth: 900, minHeight: 560)
        .sheet(item: $window.editing) { request in
            SpaceEditor(request: request, window: window)
        }
    }

    private var activeSpace: SpaceState? { window.activeSpaceID.flatMap(browser.space) }

    @ViewBuilder
    private var content: some View {
        if let space = activeSpace, let tabs = window.spaces[space.id] {
            SpaceView(window: window, space: space, tabs: tabs)
        } else {
            VStack(spacing: 12) {
                Text(browser.spaces.isEmpty ? "No spaces yet" : "Pick a space").font(.title3)
                Button("New Space…") { window.editing = EditorRequest(spaceID: nil) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The space color, strongest behind the tab strip and fading down the toolbar.
    private var tint: some View {
        let color = activeSpace?.color ?? .clear
        return LinearGradient(colors: [color.opacity(0.26), color.opacity(0.14)], startPoint: .top, endPoint: .init(x: 0.5, y: 0.15))
            .animation(.easeInOut(duration: 0.25), value: window.activeSpaceID)
            .animation(.easeInOut(duration: 0.25), value: activeSpace?.def.color)
    }
}

// MARK: - Rail

/// One icon per space, in the order saved in config. Drag icons to reorder; drop a tab on one to
/// move it to that space. The rail stays neutral so every space color reads clearly.
private struct Rail: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState

    var body: some View {
        VStack(spacing: 0) {
            // The window's traffic lights sit here; the area also drags the window.
            WindowDragArea().frame(height: 40)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 10) {
                    ForEach(Array(browser.spaces.enumerated()), id: \.element.id) { index, state in
                        RailItem(window: window, state: state, index: index)
                    }
                    Button { window.editing = EditorRequest(spaceID: nil) } label: {
                        Image(systemName: "plus")
                            .frame(width: 40, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4])))
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("New space  ⇧⌘N")
                }
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity)
            }
            Button { browser.openSettings?() } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
                    .frame(width: 40, height: 40)
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Accounts and settings  ⌘,")
        }
        .padding(.bottom, 10)
        .frame(width: 64)
        .background(Color(nsColor: .underPageBackgroundColor))
    }
}

private struct RailItem: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState
    @ObservedObject var state: SpaceState
    let index: Int
    @State private var tabOver = false

    var body: some View {
        let active = state.id == window.activeSpaceID
        Text(state.def.initials)
            .font(.system(size: 13, weight: .bold))
            .frame(width: 40, height: 40)
            .background(RoundedRectangle(cornerRadius: 12).fill(active ? state.color : state.color.opacity(tabOver ? 0.4 : 0.18)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(state.color, lineWidth: tabOver ? 2 : 0))
            .foregroundStyle(active ? Color.white : state.color)
            .overlay(alignment: .topTrailing) {
                if !active, state.unread > 0 {
                    Text(state.unread > 99 ? "99+" : "\(state.unread)")
                        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 18, minHeight: 16)
                        .background(Capsule().fill(state.color))
                        .overlay(Capsule().stroke(Color(nsColor: .underPageBackgroundColor), lineWidth: 2))
                        .offset(x: 6, y: -5)
                        .accessibilityLabel("\(state.unread) unread")
                }
            }
            .overlay(alignment: .leading) {
                if active {
                    UnevenRoundedRectangle(bottomTrailingRadius: 3, topTrailingRadius: 3)
                        .fill(state.color)
                        .frame(width: 4, height: 24)
                        .offset(x: -12)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { browser.select(state, in: window) }
            .help(state.def.name + (index < 9 ? "  ⌘\(index + 1)" : ""))
            .accessibilityElement()
            .accessibilityLabel(state.def.name + (state.unread > 0 ? ", \(state.unread) unread" : ""))
            .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { browser.select(state, in: window) }
            .contextMenu {
                Button("Edit Space…") { window.editing = EditorRequest(spaceID: state.id) }
                Divider()
                Button("Delete Space…", role: .destructive) { browser.deleteSpace(state.id) }
            }
            .onDrag {
                browser.drag = .space(state.id)
                return NSItemProvider(item: Data(state.id.utf8) as NSData, typeIdentifier: UTType.ismithSpace.identifier)
            }
            .onDrop(of: [.ismithSpace, .ismithTab], delegate: RailDropDelegate(browser: browser, window: window, target: state, tabOver: $tabOver))
    }
}

/// Reorders spaces as a dragged space passes over them, and moves a dropped tab into the space.
private struct RailDropDelegate: DropDelegate {
    let browser: BrowserState
    let window: WindowState
    let target: SpaceState
    @Binding var tabOver: Bool

    func validateDrop(info: DropInfo) -> Bool {
        browser.drag != nil
    }

    func dropEntered(info: DropInfo) {
        switch browser.drag {
        case let .space(id) where id != target.id:
            guard let to = browser.spaces.firstIndex(where: { $0.id == target.id }) else { return }
            withAnimation(.easeInOut(duration: 0.15)) { browser.moveSpace(id, to: to) }
        case let .tab(_, _, space) where space != target.id || window.activeSpaceID != target.id:
            tabOver = true
        default:
            break
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        tabOver = false
    }

    func performDrop(info: DropInfo) -> Bool {
        tabOver = false
        switch browser.drag {
        case .space:
            browser.drag = nil
            return true
        case let .tab(id, windowID, space):
            guard let source = browser.windows.first(where: { $0.id == windowID }),
                  source !== window || space != target.id else { return false }
            // Into this window's tabs for that space, at the end. A different space reloads it
            // signed in as that space.
            browser.moveTab(id, from: (source, space), to: (window, target.id), before: nil, group: nil,
                            select: window.activeSpaceID == target.id)
            return true
        case nil:
            return false
        }
    }
}

// MARK: - Space

private struct SpaceView: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState
    @ObservedObject var space: SpaceState
    @ObservedObject var tabs: SpaceTabs
    @AppStorage("showBookmarksBar") private var showBookmarksBar = true

    // One structure for both layouts, so switching keeps the page (and its web view container)
    // in place; only the strip or the sidebar comes and goes.
    var body: some View {
        let vertical = window.verticalTabs
        HStack(spacing: 0) {
            if vertical {
                // Tabs in a sidebar beside the rail; the toolbar takes the top, where the strip was.
                VerticalTabsBar(browser: browser, window: window, tabs: tabs, name: space.def.name,
                                color: Palette.nsColor(space.def.color))
                    .frame(width: 236)
            }
            VStack(spacing: 0) {
                if !vertical {
                    TabStripBar(browser: browser, window: window, tabs: tabs, name: space.def.name,
                                color: Palette.nsColor(space.def.color))
                        .frame(height: 42)
                }
                page(topInset: vertical ? 8 : 0)
            }
        }
    }

    @ViewBuilder
    private func page(topInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            if let tab = tabs.selected {
                Toolbar(window: window, space: space, tabs: tabs, tab: tab)
                    .padding(.top, topInset)
                    // Without the strip, the toolbar's empty space is the title bar: it moves the window.
                    .background { if topInset > 0 { WindowDragArea() } }
                    .id(tab.id)
                if showBookmarksBar, browser.data != nil {
                    BookmarksBar(window: window, spaceID: space.id)
                }
                RoutingBars(routing: browser.routing, window: window)
                AgentDocked(window: window, space: space) {
                    TabPage(window: window, tab: tab, color: space.color)
                        .id(tab.id)
                }
            } else {
                VStack(spacing: 10) {
                    Text("No tabs in \(space.def.name)").foregroundStyle(.secondary)
                    Button("New Tab") { browser.newTab(in: window) }
                    Text("⌘T").font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { window.window?.title = space.def.name }
            }
        }
    }
}

/// The page with what can sit above or over it: the site's questions, the find bar, a crash or a
/// failed load.
private struct TabPage: View {
    @ObservedObject var window: WindowState
    @ObservedObject var tab: Tab
    let color: Color

    var body: some View {
        VStack(spacing: 0) {
            PasswordSaveBar(tab: tab)
            PromptBar(tab: tab)
            if tab.findShown { FindBar(window: window, tab: tab) }
            WebArea(tab: tab, color: color)
        }
    }
}

private struct WebArea: View {
    @ObservedObject var tab: Tab
    let color: Color

    var body: some View {
        ZStack {
            WebContainer(webView: tab.certificateProblem == nil && !tab.crashed ? tab.webView : nil)
            if tab.webView == nil, tab.certificateProblem == nil {
                ProgressView().controlSize(.small)
            }
            if let problem = tab.certificateProblem {
                PageProblemView(tab: tab, problem: problem)
            } else if tab.crashed {
                CrashedView(tab: tab)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.5), lineWidth: 1))
        .padding([.horizontal, .bottom], 8)
    }
}

private struct Toolbar: View {
    @EnvironmentObject private var browser: BrowserState
    @EnvironmentObject private var config: Config
    @ObservedObject var window: WindowState
    @ObservedObject var space: SpaceState
    @ObservedObject var tabs: SpaceTabs
    @ObservedObject var tab: Tab
    @StateObject private var popup = SuggestionPopup()
    @StateObject private var bridge = AddressBridge()
    @State private var address = ""
    @State private var addressFocused = false
    @State private var editingBookmark: Bookmark?
    @State private var bookmarked = false
    /// Bumped on each keystroke; an older suggestion answer is dropped.
    @State private var generation = 0

    var body: some View {
        HStack(spacing: 8) {
            Button { tab.webView?.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!tab.canGoBack)
                .help("Back  ⌘[")
            Button { tab.webView?.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!tab.canGoForward)
                .help("Forward  ⌘]")
            Button { browser.reload(tab, in: tabs) } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload  ⌘R")
            HStack(spacing: 6) {
                AddressField(text: $address, placeholder: "Search \(SearchEngine.current.name) or enter address",
                             edited: edited, focusChanged: focusChanged, commit: go, cancel: cancel, move: move,
                             bridge: bridge)
                if tab.zoom != 1 {
                    Button("\(Int((tab.zoom * 100).rounded()))%") { browser.zoom(tab, by: 0) }
                        .font(.caption.monospacedDigit())
                        .help("Reset zoom  ⌘0")
                }
                // Only exceptions are shown; everything else uses the shared sign-ins.
                ForEach(exceptions, id: \.self) { label in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(space.color).frame(width: 8, height: 8)
                        Text(label).font(.caption)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 1)
                    .background(Capsule().fill(space.color.opacity(0.14)))
                    .overlay(Capsule().stroke(space.color.opacity(0.45)))
                    .fixedSize()
                }
                ShieldButton(shields: browser.shields, tab: tab)
                if browser.data != nil, tab.url != nil {
                    Button { editingBookmark = browser.bookmarkForCurrentPage(in: window) } label: {
                        Image(systemName: bookmarked ? "star.fill" : "star")
                            .foregroundStyle(bookmarked ? Color.accentColor : Color.secondary)
                    }
                    .help("Bookmark this page  ⌘D")
                    .popover(item: $editingBookmark, arrowEdge: .bottom) { bookmark in
                        BookmarkEditor(spaceID: space.id, bookmark: bookmark) { editingBookmark = nil }
                    }
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(addressFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor)))
            DownloadsToolbarItem(downloads: browser.downloads, window: window)
            AgentDockControl(window: window)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onAppear {
            address = tab.url?.absoluteString ?? ""
            updateTitle(tab.title)
            updateBookmarked()
            popup.picked = { pick($0) }
            // A new tab asked for the address bar before this toolbar existed.
            if window.pendingAddressFocus == tab.id { takeFocus() }
        }
        .onDisappear { popup.hide() }
        .onReceive(tab.$url) { url in
            if !addressFocused { address = url?.absoluteString ?? "" }
            updateBookmarked(url)
        }
        .onReceive(tab.$title, perform: updateTitle)
        .onReceive(NotificationCenter.default.publisher(for: BookmarkStore.didChange)) { _ in updateBookmarked() }
        .onReceive(window.focusRequests) { id in
            // Only for this tab; a request for a tab that was just created is picked up by its own
            // toolbar's onAppear.
            if id == nil || id == tab.id { takeFocus() }
        }
        .onReceive(window.bookmarkRequests) { editingBookmark = browser.bookmarkForCurrentPage(in: window) }
    }

    private func takeFocus() {
        window.pendingAddressFocus = nil
        bridge.focus.send()
    }

    private func focusChanged(_ focused: Bool) {
        addressFocused = focused
        if !focused {
            // Leaving the field without going anywhere shows the page's address again.
            popup.hide()
            address = tab.url?.absoluteString ?? ""
        }
    }

    private func edited(_ typed: String, deleting: Bool) {
        generation += 1
        let mine = generation
        Task {
            let result = await AddressSuggestions.compute(for: typed, space: space.id, browser: browser)
            guard mine == generation, addressFocused else { return }
            if let view = bridge.field { popup.show(result.items, below: view) }
            if !deleting, let completion = result.completion { bridge.completions.send((typed, completion)) }
        }
    }

    private func move(_ step: Int) -> Bool {
        guard popup.isShown else { return false }
        bridge.displays.send(popup.move(step)?.fieldText ?? bridge.typed)
        return true
    }

    private func pick(_ item: Suggestion) {
        popup.hide()
        if case let .openTab(id) = item.kind {
            address = tab.url?.absoluteString ?? ""
            browser.focusTab(id)
            return
        }
        open(item.url, typed: item.kind == .address || item.kind == .search, newTab: false)
    }

    private func go(newTab: Bool) {
        if let index = popup.selected, popup.items.indices.contains(index) {
            let item = popup.items[index]
            popup.hide()
            if case .openTab = item.kind { return pick(item) }
            return open(item.url, typed: false, newTab: newTab)
        }
        popup.hide()
        guard let url = AddressInput.url(for: address) else { return }
        open(url, typed: true, newTab: newTab)
    }

    private func open(_ url: URL, typed: Bool, newTab: Bool) {
        if newTab {
            browser.openTab(in: window, space: space.id, url: url)
            address = tab.url?.absoluteString ?? ""
        } else {
            browser.navigate(tab, in: tabs, to: url, typed: typed)
            address = url.absoluteString
        }
        if let webView = tab.webView { webView.window?.makeFirstResponder(webView) }
    }

    private func cancel() {
        if popup.isShown { return popup.hide() }
        address = tab.url?.absoluteString ?? ""
        if let webView = tab.webView { webView.window?.makeFirstResponder(webView) } else { window.window?.makeFirstResponder(nil) }
    }

    private func updateTitle(_ title: String) {
        window.window?.title = "\(space.def.name) — \(title)"
    }

    private func updateBookmarked(_ url: URL? = nil) {
        bookmarked = browser.isBookmarked(url ?? tab.url, space: space.id)
    }

    private var exceptions: [String] {
        config.providers.compactMap { p in
            switch space.def.bindings[p.id] {
            case nil: return nil
            case SpaceDef.local: return "\(p.name): this space only"
            case let id?: return config.account(id).map { "\(p.name): \($0.name)" }
            }
        }
    }
}

/// Shows the downloads button once there's a download (or the panel is open).
private struct DownloadsToolbarItem: View {
    @ObservedObject var downloads: DownloadManager
    @ObservedObject var window: WindowState

    var body: some View {
        if !downloads.items.isEmpty || window.downloadsShown {
            DownloadsButton(downloads: downloads, shown: $window.downloadsShown)
        }
    }
}

/// The page with the agent panel beside it (right) or under it (bottom), as the window's dock
/// control says. The panel's inner edge drags to resize it; the size is remembered, and a
/// double-click on the edge restores the default.
private struct AgentDocked<Page: View>: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState
    @ObservedObject var space: SpaceState
    @ViewBuilder let page: () -> Page
    @AppStorage("agentPanelWidth") private var width: Double = AgentPanelSize.defaultWidth
    @AppStorage("agentPanelHeight") private var height: Double = AgentPanelSize.defaultHeight

    var body: some View {
        GeometryReader { geo in
            switch window.agentDock {
            case .right:
                let shown = AgentPanelSize.clampWidth(width, available: geo.size.width)
                HStack(spacing: 0) {
                    page()
                    AgentPanel(agent: browser.agent, session: browser.agent.session(space.id), space: space, dock: .right)
                        .frame(width: shown)
                        .overlay(alignment: .leading) { Rectangle().fill(space.color.opacity(0.3)).frame(width: 1) }
                        .overlay(alignment: .leading) {
                            PanelResizeHandle(axis: .horizontal) { delta in
                                width = AgentPanelSize.clampWidth(shown - delta, available: geo.size.width)
                            } reset: { width = AgentPanelSize.defaultWidth }
                        }
                }
            case .bottom:
                let shown = AgentPanelSize.clampHeight(height, available: geo.size.height)
                VStack(spacing: 0) {
                    page()
                    AgentPanel(agent: browser.agent, session: browser.agent.session(space.id), space: space, dock: .bottom)
                        .frame(height: shown)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(space.color.opacity(0.35)))
                        .overlay(alignment: .top) {
                            PanelResizeHandle(axis: .vertical) { delta in
                                height = AgentPanelSize.clampHeight(shown - delta, available: geo.size.height)
                            } reset: { height = AgentPanelSize.defaultHeight }
                        }
                        .padding([.horizontal, .bottom], 8)
                }
            case .hidden:
                page()
            }
        }
    }
}

/// Size limits for the agent panel: never so small it's unusable, never more than 70% of the
/// window, so the page always stays visible.
enum AgentPanelSize {
    static let defaultWidth: Double = 330
    static let defaultHeight: Double = 230

    static func clampWidth(_ value: Double, available: Double) -> Double {
        min(max(value, 260), max(260, available * 0.7))
    }

    static func clampHeight(_ value: Double, available: Double) -> Double {
        min(max(value, 140), max(140, available * 0.7))
    }
}

/// A thin, invisible strip on the panel's inner edge with a resize cursor. Reports how far it was
/// dragged towards the page (negative) or the panel (positive) since the last change.
private struct PanelResizeHandle: View {
    enum Axis { case horizontal, vertical }
    let axis: Axis
    let changed: (Double) -> Void
    let reset: () -> Void
    @State private var last: Double = 0
    @State private var hovering = false

    var body: some View {
        Color.clear
            .frame(width: axis == .horizontal ? 8 : nil, height: axis == .vertical ? 8 : nil)
            .offset(x: axis == .horizontal ? -4 : 0, y: axis == .vertical ? -4 : 0)
            .contentShape(Rectangle())
            .onHover { inside in
                guard inside != hovering else { return }
                hovering = inside
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { drag in
                        let total = axis == .horizontal ? drag.translation.width : drag.translation.height
                        changed(total - last)
                        last = total
                    }
                    .onEnded { _ in last = 0 }
            )
            .onTapGesture(count: 2, perform: reset)
            .onDisappear { if hovering { NSCursor.pop(); hovering = false } }
            .help("Drag to resize the agent panel; double-click to reset")
            .accessibilityLabel("Resize agent panel")
    }
}

// MARK: - AppKit pieces

/// Shows the selected tab's web view. One container stays in place while tabs come and go, so a
/// web view can move to another window without SwiftUI holding on to it.
struct WebContainer: NSViewRepresentable {
    let webView: WKWebView?

    func makeNSView(context: Context) -> WebContainerView { WebContainerView() }

    func updateNSView(_ view: WebContainerView, context: Context) {
        view.show(webView)
    }
}

final class WebContainerView: NSView {
    func show(_ webView: WKWebView?) {
        guard subviews.first !== webView || (webView == nil && !subviews.isEmpty) else { return }
        subviews.forEach { $0.removeFromSuperview() }
        guard let webView else { return }
        webView.frame = bounds
        webView.autoresizingMask = [.width, .height]
        addSubview(webView)
        // The page takes focus unless something else (the address bar) has it.
        if let window, window.firstResponder === window || window.firstResponder == nil {
            window.makeFirstResponder(webView)
        }
    }
}

/// Empty chrome that moves the window, since the window has no visible title bar.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ view: DragView, context: Context) {}

    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: event) }
        }
    }
}
