import AppKit
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

    var body: some View {
        VStack(spacing: 0) {
            TabStripBar(browser: browser, window: window, tabs: tabs, name: space.def.name,
                        color: Palette.nsColor(space.def.color))
                .frame(height: 42)
            if let tab = tabs.selected {
                Toolbar(window: window, space: space, tabs: tabs, tab: tab)
                    .id(tab.id)
                WebArea(tab: tab, color: space.color)
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

private struct WebArea: View {
    @ObservedObject var tab: Tab
    let color: Color

    var body: some View {
        WebContainer(webView: tab.webView)
            .overlay {
                if tab.webView == nil { ProgressView().controlSize(.small) }
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
    @State private var address = ""
    @FocusState private var addressFocused: Bool

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
                TextField("Search or enter address", text: $address)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($addressFocused)
                    .onSubmit(go)
                    .onExitCommand {
                        address = tab.url?.absoluteString ?? ""
                        addressFocused = false
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
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(addressFocused ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor)))
            Menu("Go") {
                ForEach(QuickLink.all) { link in
                    Button(link.name) { browser.navigate(tab, in: tabs, to: link.url) }
                }
            }
            .fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
        .onAppear {
            address = tab.url?.absoluteString ?? ""
            updateTitle(tab.title)
            // A new tab asked for the address bar before this toolbar existed.
            if window.pendingAddressFocus == tab.id { takeFocus() }
        }
        .onReceive(tab.$url) { url in
            if !addressFocused { address = url?.absoluteString ?? "" }
        }
        .onReceive(tab.$title, perform: updateTitle)
        .onChange(of: addressFocused) { _, focused in
            // Leaving the field without going anywhere shows the page's address again.
            if !focused { address = tab.url?.absoluteString ?? "" }
        }
        .onReceive(window.focusRequests) { id in
            // Only for this tab; a request for a tab that was just created is picked up by its own
            // toolbar's onAppear.
            if id == nil || id == tab.id { takeFocus() }
        }
    }

    private func takeFocus() {
        window.pendingAddressFocus = nil
        // On the next turn, once the field is in the window.
        DispatchQueue.main.async { addressFocused = true }
    }

    private func updateTitle(_ title: String) {
        window.window?.title = "\(space.def.name) — \(title)"
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

    private func go() {
        guard let url = AddressInput.url(for: address) else { return }
        browser.navigate(tab, in: tabs, to: url)
        address = url.absoluteString
        addressFocused = false
        if let webView = tab.webView { webView.window?.makeFirstResponder(webView) }
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
