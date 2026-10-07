import AppKit
import BrowserData
import SecurityInterface
import SwiftUI
import WebKit

/// A page's question (permission, app link) as a bar above the page.
struct PromptBar: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var tab: Tab

    var body: some View {
        if let prompt = tab.prompts.first {
            HStack(spacing: 10) {
                Image(systemName: prompt.symbol).foregroundStyle(.secondary)
                Text(prompt.message).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let deny = prompt.denyTitle {
                    Button(deny) { browser.answer(prompt, .deny, in: tab) }
                }
                if let always = prompt.alwaysTitle {
                    Button(always) { browser.answer(prompt, .always, in: tab) }
                }
                Button(prompt.allowTitle) { browser.answer(prompt, .allow, in: tab) }
                    .buttonStyle(.borderedProminent)
                if tab.prompts.count > 1 {
                    Text("+\(tab.prompts.count - 1)").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 12.5))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(nsColor: .separatorColor)))
            .padding(.horizontal, 8).padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Site question")
        }
    }
}

/// Find in page: ⌘F shows it, Return and ⌘G find the next match, ⇧Return and ⌘⇧G the previous,
/// Escape closes it.
struct FindBar: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState
    @ObservedObject var tab: Tab
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find on page", text: $tab.findText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
                .focused($focused)
                .onSubmit { browser.find(tab, backwards: NSEvent.modifierFlags.contains(.shift)) }
                .onExitCommand { browser.hideFind(tab) }
                .onChange(of: tab.findText) { _, _ in browser.find(tab) }
            Button { browser.find(tab, backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous  ⇧⌘G")
            Button { browser.find(tab) } label: { Image(systemName: "chevron.down") }
                .help("Next  ⌘G")
            if tab.findResult == false {
                Text("Not found").font(.caption).foregroundStyle(.red)
            }
            Spacer()
            Button("Done") { browser.hideFind(tab) }
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.bottom, 6)
        .onAppear { focused = true }
        .onReceive(window.findFocusRequests) { focused = true }
    }
}

/// Shown over the page: the web content process died.
struct CrashedView: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var tab: Tab

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 34)).foregroundStyle(.secondary)
            Text("This page stopped working").font(.title3)
            Text(tab.url?.host ?? "").foregroundStyle(.secondary)
            Button("Reload") { browser.reloadAfterCrash(tab) }
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// Shown instead of the page when a load failed: a certificate warning (with "Visit This
/// Website" under Details) or a site that couldn't be reached.
struct PageProblemView: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var tab: Tab
    let problem: CertificateProblem
    @State private var details = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: problem.isCertificate ? "lock.trianglebadge.exclamationmark" : "wifi.exclamationmark")
                .font(.system(size: 38)).foregroundStyle(problem.isCertificate ? .red : .secondary)
            Text(problem.isCertificate ? "This connection isn't private" : "iSmith can't open this page")
                .font(.title2.weight(.semibold))
            Text(problem.isCertificate
                 ? "\(problem.url.host ?? "This site") may be pretending to be the site you want, to steal passwords or other information. \(problem.message)"
                 : "\(problem.url.host ?? "The site") couldn't be reached. \(problem.message)")
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if problem.isCertificate {
                    Button("Go Back") { goBack() }.keyboardShortcut(.defaultAction)
                    Button(details ? "Hide Details" : "Show Details") { details.toggle() }
                } else {
                    Button("Try Again") {
                        tab.certificateProblem = nil
                        tab.webView?.load(URLRequest(url: problem.url))
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            if details, let trust = problem.trust {
                VStack(alignment: .leading, spacing: 8) {
                    Button("Show Certificate") { showCertificate(trust) }
                    Button("Visit This Website Anyway") { browser.proceedDespiteCertificate(tab) }
                        .foregroundStyle(.red)
                    Text("Only for this run of iSmith, and only for this certificate.").font(.caption).foregroundStyle(.secondary)
                }
                .buttonStyle(.link)
            }
        }
        .frame(maxWidth: 520)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func goBack() {
        tab.certificateProblem = nil
        if let webView = tab.webView, webView.canGoBack { webView.goBack() }
    }

    private func showCertificate(_ trust: SecTrust) {
        guard let window = tab.webView?.window ?? NSApp.keyWindow else { return }
        SFCertificateTrustPanel().beginSheet(for: window, modalDelegate: nil, didEnd: nil, contextInfo: nil, trust: trust,
                                             message: problem.url.host ?? "")
    }
}

// MARK: - Bookmarks bar

/// The bookmarks bar: the "Bookmarks Bar" folder, the same in every space; folders open as menus.
/// Only the items that fit are shown; the rest are in a » menu at the right end, as in other
/// browsers. Bookmarks open in the window's current space. Drag an item to reorder it or onto a
/// folder; dropping on the bar's empty space puts it at the end.
struct BookmarksBar: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState
    @State private var bar: Bookmark?
    @State private var items: [BookmarkTree] = []
    @State private var dropOver: BookmarkDropTarget?
    /// Each item's natural width, measured off-screen, keyed by bookmark id.
    @State private var widths: [Int64: CGFloat] = [:]

    private static let spacing: CGFloat = 2
    private static let overflowWidth: CGFloat = 30
    private static let sidePadding: CGFloat = 8

    var body: some View {
        GeometryReader { geo in
            // A small margin, so rounding never squeezes the last item that fits.
            let shown = visibleCount(available: geo.size.width - Self.sidePadding * 2 - 8)
            HStack(spacing: Self.spacing) {
                if items.isEmpty {
                    Text("Bookmarks you add to the bar appear here (⌘D)")
                        .font(.caption).foregroundStyle(.tertiary).padding(.leading, 6)
                }
                ForEach(Array(items.prefix(shown).enumerated()), id: \.element.bookmark.id) { index, node in
                    BookmarkBarItem(window: window, node: node)
                        .fixedSize()
                        .modifier(BookmarkDragDrop(bookmark: node.bookmark, parent: bar?.id, index: index,
                                                   horizontal: true, over: $dropOver))
                }
                Spacer(minLength: 0)
                if shown < items.count {
                    Menu {
                        BookmarkMenuContent(nodes: Array(items.dropFirst(shown))) {
                            browser.openBookmark($0, in: window, newTab: NSEvent.modifierFlags.contains(.command))
                        }
                    } label: {
                        Image(systemName: "chevron.right.2")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .frame(width: Self.overflowWidth)
                    .help("\(items.count - shown) more bookmarks")
                }
            }
            .padding(.horizontal, Self.sidePadding)
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .background {
                // The bar itself, behind the items: a drop here goes at the end.
                if let bar {
                    Color.clear.contentShape(Rectangle())
                        .modifier(BookmarkDragDrop(bookmark: bar, parent: nil, index: 0, horizontal: true, over: $dropOver))
                }
            }
        }
        .frame(height: 24)
        .background(alignment: .topLeading) { measurer }
        .padding(.bottom, 4)
        .onAppear(perform: reload)
        .onReceive(NotificationCenter.default.publisher(for: BookmarkStore.didChange)) { _ in reload() }
    }

    /// Lays every item out at its natural size, invisibly, to learn its width.
    private var measurer: some View {
        HStack(spacing: Self.spacing) {
            ForEach(items, id: \.bookmark.id) { node in
                BookmarkBarItem(window: window, node: node)
                    .fixedSize()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: BookmarkWidths.self, value: [node.bookmark.id: proxy.size.width])
                    })
            }
        }
        .fixedSize()
        .frame(width: 0, height: 0, alignment: .topLeading)
        .hidden()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onPreferenceChange(BookmarkWidths.self) { widths = $0 }
    }

    /// How many items fit in `available` points. If not all of them do, room is kept for the »
    /// button.
    private func visibleCount(available: CGFloat) -> Int {
        let sizes = items.map { (widths[$0.bookmark.id] ?? 120) + Self.spacing }
        if sizes.reduce(0, +) <= available { return items.count }
        var used: CGFloat = 0
        for (index, size) in sizes.enumerated() {
            if used + size + Self.overflowWidth > available { return index }
            used += size
        }
        return items.count
    }

    private func reload() {
        let tree = (try? browser.data?.bookmarks.tree()) ?? []
        let root = tree.first { $0.bookmark.root == .bar }
        bar = root?.bookmark
        items = root?.children ?? []
    }
}

private struct BookmarkWidths: PreferenceKey {
    static var defaultValue: [Int64: CGFloat] = [:]
    static func reduce(value: inout [Int64: CGFloat], nextValue: () -> [Int64: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct BookmarkBarItem: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var window: WindowState
    let node: BookmarkTree

    @State private var hovering = false

    // Plain views with a tap, not Button or Menu: those track the mouse in AppKit and swallow the
    // drag that reorders the bar.
    var body: some View {
        Group {
            if node.bookmark.isFolder {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                    Text(node.bookmark.title).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
            } else {
                Text(node.bookmark.title.isEmpty ? (node.bookmark.url ?? "") : node.bookmark.title)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
                    .help(node.bookmark.url ?? "")
                    .contextMenu {
                    Button("Open in New Tab") { open(node.bookmark, newTab: true) }
                    Button("Copy Address") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(node.bookmark.url ?? "", forType: .string)
                    }
                    Divider()
                    Button("Delete") { try? browser.data?.bookmarks.delete(node.bookmark.id) }
                }
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: activate)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { activate() }
    }

    private func activate() {
        if node.bookmark.isFolder { showFolder() } else {
            open(node.bookmark, newTab: NSEvent.modifierFlags.contains(.command))
        }
    }

    private func open(_ bookmark: Bookmark, newTab: Bool) {
        browser.openBookmark(bookmark, in: window, newTab: newTab)
    }

    /// The folder's contents as a menu at the pointer.
    private func showFolder() {
        menu(node.children).popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    private func menu(_ nodes: [BookmarkTree]) -> NSMenu {
        let menu = NSMenu()
        if nodes.isEmpty {
            let empty = NSMenuItem(title: "Empty", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        }
        for child in nodes {
            let bookmark = child.bookmark
            if bookmark.isFolder {
                let item = NSMenuItem(title: bookmark.title, action: nil, keyEquivalent: "")
                item.submenu = self.menu(child.children)
                menu.addItem(item)
            } else {
                let item = ActionItem(bookmark.title.isEmpty ? (bookmark.url ?? "") : bookmark.title) {
                    open(bookmark, newTab: NSEvent.modifierFlags.contains(.command))
                }
                item.toolTip = bookmark.url
                menu.addItem(item)
            }
        }
        return menu
    }
}

/// A folder's contents as menu items (the bar's folders).
struct BookmarkMenuContent: View {
    let nodes: [BookmarkTree]
    let open: (Bookmark) -> Void

    var body: some View {
        if nodes.isEmpty {
            Text("Empty")
        }
        ForEach(nodes, id: \.bookmark.id) { node in
            if node.bookmark.isFolder {
                Menu(node.bookmark.title) { BookmarkMenuContent(nodes: node.children, open: open) }
            } else {
                Button(node.bookmark.title.isEmpty ? (node.bookmark.url ?? "") : node.bookmark.title) { open(node.bookmark) }
            }
        }
    }
}

/// ⌘D and the star: name the bookmark and pick its folder, or remove it.
struct BookmarkEditor: View {
    @EnvironmentObject private var browser: BrowserState
    let bookmark: Bookmark
    let done: () -> Void
    @State private var title: String
    @State private var folder: Int64
    @State private var folders: [(id: Int64, name: String)] = []

    init(bookmark: Bookmark, done: @escaping () -> Void) {
        self.bookmark = bookmark
        self.done = done
        _title = State(initialValue: bookmark.title)
        _folder = State(initialValue: bookmark.parentID ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bookmark").font(.headline)
            TextField("Name", text: $title).textFieldStyle(.roundedBorder)
            Picker("Folder", selection: $folder) {
                ForEach(folders, id: \.id) { Text($0.name).tag($0.id) }
            }
            HStack {
                Button("Remove") {
                    try? browser.data?.bookmarks.delete(bookmark.id)
                    done()
                }
                Spacer()
                Button("Done") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { folders = BookmarkFolders.list(browser.data?.bookmarks) }
    }

    private func save() {
        let store = browser.data?.bookmarks
        if title != bookmark.title { try? store?.update(bookmark.id, title: title, url: nil) }
        if folder != bookmark.parentID, folder != 0 { try? store?.move(bookmark.id, to: folder, at: nil) }
        done()
    }
}

/// Every bookmark folder, indented by depth, for pickers.
enum BookmarkFolders {
    static func list(_ store: BookmarkStore?) -> [(id: Int64, name: String)] {
        var out: [(Int64, String)] = []
        func walk(_ nodes: [BookmarkTree], depth: Int) {
            for node in nodes where node.bookmark.isFolder {
                out.append((node.bookmark.id, String(repeating: "    ", count: depth) + node.bookmark.title))
                walk(node.children, depth: depth + 1)
            }
        }
        walk((try? store?.tree()) ?? [], depth: 0)
        return out.map { (id: $0.0, name: $0.1) }
    }
}
