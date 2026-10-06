import AppKit
import BrowserData
import SwiftUI
import WebKit

// History (⌘Y, per space) and bookmarks (bar, menu, manager; one set shared by every space).

extension BrowserState {
    /// Opens a bookmark in the window's current space: in the tab on screen, or a new tab. A
    /// bookmarklet (javascript:) runs on the page on screen.
    func openBookmark(_ bookmark: Bookmark, in window: WindowState, newTab: Bool) {
        guard let string = bookmark.url else { return }
        if string.lowercased().hasPrefix("javascript:") {
            let code = String(string.dropFirst("javascript:".count)).removingPercentEncoding ?? ""
            window.active?.selected?.webView?.evaluateJavaScript(code, in: nil, in: .page)
            return
        }
        guard let url = URL(string: string) ?? AddressInput.url(for: string), let spaceID = window.activeSpaceID else { return }
        if !newTab, let tabs = window.active, let tab = tabs.selected {
            navigate(tab, in: tabs, to: url)
        } else {
            openTab(in: window, space: spaceID, url: url)
        }
    }

    /// Opens a page from history or the manager in its own space in this window.
    func open(_ url: URL, space spaceID: String, in window: WindowState) {
        guard let space = space(spaceID) ?? window.activeSpaceID.flatMap(space) else { return }
        openTab(in: window, space: space.id, url: url)
        if window.activeSpaceID != space.id { select(space, in: window) }
        window.window?.makeKeyAndOrderFront(nil)
    }

    /// ⌘D: the page's bookmark, created on the bookmarks bar if there isn't one.
    func bookmarkForCurrentPage(in window: WindowState) -> Bookmark? {
        guard let store = data?.bookmarks, let tab = window.active?.selected,
              let url = tab.url, ["http", "https", "file"].contains(url.scheme ?? "") else { return nil }
        if let existing = try? store.bookmarks(url: url.absoluteString).first { return existing }
        return try? store.add(parent: nil, title: tab.title, url: url.absoluteString)
    }

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return !((try? data?.bookmarks.bookmarks(url: url.absoluteString)) ?? []).isEmpty
    }
}

// MARK: - History window

/// ⌘Y: every visit in a space (or all spaces), newest first, grouped by day, with search.
struct HistoryView: View {
    @EnvironmentObject private var browser: BrowserState
    /// nil = every space.
    @State var space: String?
    @State private var query = ""
    @State private var rows: [HistoryVisitRow] = []
    @State private var selection = Set<Int64>()
    @State private var limit = 300

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Space", selection: $space) {
                    Text("All Spaces").tag(String?.none)
                    ForEach(browser.spaces) { Text($0.def.name).tag(String?.some($0.id)) }
                }
                .labelsHidden()
                .frame(width: 180)
                TextField("Search history", text: $query)
                    .textFieldStyle(.roundedBorder)
                Menu("Clear") {
                    Button("Last Hour") { clear(since: Date().addingTimeInterval(-3600)) }
                    Button("Today") { clear(since: Calendar.current.startOfDay(for: Date())) }
                    Button("All History in \(spaceName)") { clear(since: nil) }
                }
                .fixedSize()
            }
            .padding(10)
            Divider()
            List(selection: $selection) {
                ForEach(days, id: \.0) { day, visits in
                    Section(day) {
                        ForEach(visits) { row in
                            HStack(spacing: 8) {
                                Text(row.visitedAt, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                    .frame(width: 64, alignment: .leading)
                                Text(row.title?.isEmpty == false ? row.title! : row.url).lineLimit(1)
                                Text(URL(string: row.url)?.host ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                if space == nil {
                                    Text(browser.space(row.space)?.def.name ?? row.space).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .tag(row.visitID)
                            .contextMenu {
                                Button("Open") { open(row) }
                                Button("Copy Address") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(row.url, forType: .string)
                                }
                                Divider()
                                Button("Delete") { delete(selection.contains(row.visitID) ? Array(selection) : [row.visitID]) }
                                Button("Delete All Visits to This Page") {
                                    if let url = URL(string: row.url) { try? browser.data?.history.deleteURL(space: row.space, url: url) }
                                    reload()
                                }
                            }
                        }
                    }
                }
                if rows.count >= limit {
                    Button("Show More") { limit += 300; reload() }
                }
            }
            .contextMenu(forSelectionType: Int64.self, menu: { _ in }, primaryAction: { ids in
                for id in ids { if let row = rows.first(where: { $0.visitID == id }) { open(row) } }
            })
            .onDeleteCommand { delete(Array(selection)) }
            if browser.data == nil {
                Text("History isn't available: iSmith couldn't open its database.").foregroundStyle(.secondary).padding()
            }
        }
        .frame(minWidth: 560, minHeight: 400)
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reload() }
        .onChange(of: space) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChange).debounce(for: .milliseconds(500), scheduler: RunLoop.main)) { _ in reload() }
    }

    private var spaceName: String { space.flatMap { browser.space($0)?.def.name } ?? "All Spaces" }

    private var days: [(String, [HistoryVisitRow])] {
        let formatter = DateFormatter()
        formatter.dateStyle = .full
        formatter.doesRelativeDateFormatting = true
        var out: [(String, [HistoryVisitRow])] = []
        for row in rows {
            let day = formatter.string(from: row.visitedAt)
            if out.last?.0 == day { out[out.count - 1].1.append(row) } else { out.append((day, [row])) }
        }
        return out
    }

    private func reload() {
        rows = (try? browser.data?.history.visits(space: space, matching: query, limit: limit)) ?? []
        selection.formIntersection(rows.map(\.visitID))
    }

    private func open(_ row: HistoryVisitRow) {
        guard let url = URL(string: row.url), let window = browser.currentWindow else { return }
        browser.open(url, space: row.space, in: window)
    }

    private func delete(_ ids: [Int64]) {
        guard !ids.isEmpty else { return }
        try? browser.data?.history.delete(visitIDs: ids)
        reload()
    }

    private func clear(since: Date?) {
        try? browser.data?.history.clear(space: space, since: since)
        reload()
    }
}

// MARK: - Bookmarks manager

/// ⌥⌘B: the bookmarks (shared by every space) as a tree. Rename, change the address, add
/// folders, move between folders, delete. Opening one opens it in the current window's space.
struct BookmarksManager: View {
    @EnvironmentObject private var browser: BrowserState
    @State private var tree: [BookmarkTree] = []
    @State private var query = ""
    @State private var results: [Bookmark] = []
    @State private var selection: Int64?
    @State private var editing: Bookmark?
    /// Open folders (roots are open unless collapsed).
    @State private var expanded = Set<Int64>()
    @State private var collapsed = Set<Int64>()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                TextField("Search bookmarks", text: $query).textFieldStyle(.roundedBorder)
                Button { newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }
            }
            .padding(10)
            Divider()
            List(selection: $selection) {
                if query.isEmpty {
                    ForEach(tree, id: \.bookmark.id) { node(_: $0) }
                } else {
                    ForEach(results) { row($0) }
                }
            }
            .onDeleteCommand { if let id = selection { delete(id) } }
        }
        .frame(minWidth: 560, minHeight: 420)
        .sheet(item: $editing) { bookmark in
            BookmarkEditSheet(bookmark: bookmark) { editing = nil }
        }
        .onAppear(perform: reload)
        .onChange(of: query) { _, _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: BookmarkStore.didChange)) { _ in reload() }
    }

    /// A folder opens and closes; the two roots start open.
    private func node(_ node: BookmarkTree) -> AnyView {
        guard node.bookmark.isFolder else { return AnyView(row(node.bookmark)) }
        let id = node.bookmark.id
        let open = Binding(get: { node.bookmark.root != nil ? !collapsed.contains(id) : expanded.contains(id) },
                           set: { on in
                               if node.bookmark.root != nil {
                                   if on { collapsed.remove(id) } else { collapsed.insert(id) }
                               } else if on { expanded.insert(id) } else { expanded.remove(id) }
                           })
        return AnyView(DisclosureGroup(isExpanded: open) {
            ForEach(node.children, id: \.bookmark.id) { self.node($0) }
        } label: {
            row(node.bookmark)
        })
    }

    private func row(_ b: Bookmark) -> some View {
        HStack(spacing: 8) {
            Image(systemName: b.isFolder ? "folder" : "globe").foregroundStyle(.secondary)
            Text(b.title.isEmpty ? (b.url ?? "") : b.title).lineLimit(1)
            if let url = b.url { Text(url).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
        }
        .tag(b.id)
        .contextMenu { menu(for: b) }
        .onTapGesture(count: 2) { open(b) }
    }

    @ViewBuilder
    private func menu(for b: Bookmark) -> some View {
        if !b.isFolder { Button("Open") { open(b) } }
        if b.root == nil {
            Button(b.isFolder ? "Rename…" : "Edit…") { editing = b }
            Menu("Move to Folder") {
                ForEach(BookmarkFolders.list(browser.data?.bookmarks).filter { $0.id != b.id }, id: \.id) { folder in
                    Button(folder.name) { try? browser.data?.bookmarks.move(b.id, to: folder.id, at: nil) }
                }
            }
            Divider()
            Button("Delete") { delete(b.id) }
        }
        if b.isFolder { Button("New Folder Inside") { newFolder(in: b.id) } }
    }

    private func reload() {
        let store = browser.data?.bookmarks
        // Both roots exist from the start, so the tree always shows them.
        tree = (try? store?.tree()) ?? []
        results = query.isEmpty ? [] : ((try? store?.search(query, limit: 200)) ?? [])
    }

    /// In a new tab in the current window's space.
    private func open(_ b: Bookmark) {
        guard let s = b.url, let url = URL(string: s), let window = browser.currentWindow,
              let space = window.activeSpaceID ?? browser.spaces.first?.id else { return }
        browser.open(url, space: space, in: window)
    }

    private func delete(_ id: Int64) {
        try? browser.data?.bookmarks.delete(id)
    }

    private func newFolder(in parent: Int64? = nil) {
        guard let store = browser.data?.bookmarks else { return }
        let target = parent ?? (selection.flatMap { try? store.bookmark(id: $0) }.flatMap { $0.isFolder ? $0.id : $0.parentID })
        if let folder = try? store.addFolder(parent: target, title: "New Folder") { editing = folder }
    }
}

private struct BookmarkEditSheet: View {
    @EnvironmentObject private var browser: BrowserState
    let bookmark: Bookmark
    let done: () -> Void
    @State private var title = ""
    @State private var url = ""

    var body: some View {
        Form {
            TextField("Name", text: $title)
            if !bookmark.isFolder { TextField("Address", text: $url) }
            HStack {
                Spacer()
                Button("Cancel", action: done).keyboardShortcut(.cancelAction)
                Button("Save") {
                    try? browser.data?.bookmarks.update(bookmark.id, title: title, url: bookmark.isFolder ? nil : url)
                    done()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .onAppear {
            title = bookmark.title
            url = bookmark.url ?? ""
        }
    }
}

// MARK: - Bookmarks menu

/// The Bookmarks menu in the menu bar: the bookmarks bar and other bookmarks (the same in every
/// space), rebuilt each time it opens. Bookmarks open in the current window's space.
@MainActor
final class BookmarksMenu: NSObject, NSMenuDelegate {
    private let browser: BrowserState
    private let fixedCount: Int

    init(browser: BrowserState, fixedCount: Int) {
        self.browser = browser
        self.fixedCount = fixedCount
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        while menu.items.count > fixedCount { menu.removeItem(at: fixedCount) }
        guard let window = browser.currentWindow, window.activeSpaceID != nil,
              let tree = try? browser.data?.bookmarks.tree() else { return }
        menu.addItem(.separator())
        for root in tree {
            if root.bookmark.root == .bar {
                add(root.children, to: menu, window: window)
            } else if !root.children.isEmpty {
                let item = NSMenuItem(title: root.bookmark.title, action: nil, keyEquivalent: "")
                item.submenu = submenu(root.children, window: window)
                menu.addItem(item)
            }
        }
    }

    private func add(_ nodes: [BookmarkTree], to menu: NSMenu, window: WindowState) {
        for node in nodes.prefix(200) {
            if node.bookmark.isFolder {
                let item = NSMenuItem(title: node.bookmark.title, action: nil, keyEquivalent: "")
                item.submenu = submenu(node.children, window: window)
                item.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
                menu.addItem(item)
            } else {
                let bookmark = node.bookmark
                let item = ActionItem(bookmark.title.isEmpty ? (bookmark.url ?? "") : bookmark.title) { [weak self, weak window] in
                    guard let window else { return }
                    self?.browser.openBookmark(bookmark, in: window, newTab: NSEvent.modifierFlags.contains(.command))
                }
                item.toolTip = bookmark.url
                menu.addItem(item)
            }
        }
    }

    private func submenu(_ nodes: [BookmarkTree], window: WindowState) -> NSMenu {
        let sub = NSMenu()
        if nodes.isEmpty { sub.addItem(withTitle: "Empty", action: nil, keyEquivalent: "") }
        add(nodes, to: sub, window: window)
        return sub
    }
}
