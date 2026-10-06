import AppKit
import BrowserData

/// How windows show their tabs: across the top (the strip) or in a sidebar beside the rail. Each
/// window keeps its own choice in the session; this is the one new windows start with.
enum TabLayoutStyle {
    static let defaultsKey = "verticalTabs"

    static var verticalByDefault: Bool {
        get { UserDefaults.standard.bool(forKey: defaultsKey) }
        set { UserDefaults.standard.set(newValue, forKey: defaultsKey) }
    }
}

/// Pinned tabs and the actions on several tabs at once (the selection made with ⌘-click and
/// ⇧-click in the strip, the sidebar or the tab overview).
extension BrowserState {
    // MARK: Pinned tabs

    /// Pins tabs: icon-only at the start of the space's strip, saved with the session.
    func pin(_ ids: [UUID], in tabs: SpaceTabs) {
        tabs.update { $0.pin(ids) }
        tabs.marked = []
        scheduleRefresh()
    }

    func unpin(_ ids: [UUID], in tabs: SpaceTabs) {
        tabs.update { $0.unpin(ids) }
        tabs.marked = []
        scheduleRefresh()
    }

    // MARK: Closing

    /// "Close Other Tabs": every unpinned tab but these.
    func closeOthers(than ids: [UUID], in tabs: SpaceTabs) {
        closeTabs(tabs.layout.others(than: ids), in: tabs)
    }

    /// "Close Tabs to the Right": the unpinned tabs right of the rightmost of these.
    func closeTabsRight(of ids: [UUID], in tabs: SpaceTabs) {
        closeTabs(tabs.layout.tabsRight(of: ids), in: tabs)
    }

    // MARK: Copying, sorting, bookmarking

    /// Duplicates tabs, each copy right after its tab, with its history. One tab's copy is
    /// selected; several copies open in the background.
    func duplicate(_ ids: [UUID], in tabs: SpaceTabs, window: WindowState) {
        guard ids.count > 1 else {
            if let id = ids.first { duplicate(id, in: tabs, window: window) }
            return
        }
        for id in ids {
            guard let tab = tabs.tab(id) else { continue }
            openTab(in: window, space: tabs.spaceID, url: tab.url, title: tab.title, keepAlive: tab.keepAliveSetting,
                    state: tab.history, select: false) { layout, new in
                layout.insert(new, after: id)
            }
        }
        tabs.marked = []
    }

    /// The key tabs sort by: the site (without "www."), then the title.
    static func siteKey(_ tab: Tab?) -> String {
        guard let tab else { return "" }
        var host = tab.url?.host?.lowercased() ?? "~"
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host + "\u{1}" + tab.title.lowercased()
    }

    /// Sorts tabs by site. Several tabs sort among themselves; one tab sorts the run it's in
    /// (the pinned tabs, its group, or the ungrouped tabs). Groups and pins don't change.
    func sortBySite(_ ids: [UUID], in tabs: SpaceTabs) {
        let ids = ids.count > 1 ? ids : ids.first.map { tabs.layout.run(of: $0) } ?? []
        tabs.update { $0.sort(ids) { Self.siteKey(tabs.tab($0)) } }
        scheduleRefresh()
    }

    /// Bookmarks tabs in the space. Several go into a new folder in Other Bookmarks, named for the
    /// space and the date; one goes on the bookmarks bar (unless it's already bookmarked).
    /// Returns the folder (or bookmark) made, nil if there was nothing to bookmark.
    @discardableResult
    func bookmarkAll(_ ids: [UUID], in tabs: SpaceTabs) -> Bookmark? {
        guard let store = data?.bookmarks else { return nil }
        let pages = ids.compactMap { tabs.tab($0) }.compactMap { tab -> (String, URL)? in
            guard let url = tab.url, ["http", "https", "file"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return (tab.title, url)
        }
        guard !pages.isEmpty else { return nil }
        if pages.count == 1, let (title, url) = pages.first {
            if let existing = try? store.bookmarks(space: tabs.spaceID, url: url.absoluteString).first { return existing }
            return try? store.add(space: tabs.spaceID, parent: nil, title: title, url: url.absoluteString)
        }
        let name = (space(tabs.spaceID)?.def.name ?? "Tabs") + " tabs, "
            + Date().formatted(date: .abbreviated, time: .shortened)
        guard let other = try? store.root(.other, space: tabs.spaceID),
              let folder = try? store.addFolder(space: tabs.spaceID, parent: other.id, title: name) else { return nil }
        for (title, url) in pages {
            _ = try? store.add(space: tabs.spaceID, parent: folder.id, title: title, url: url.absoluteString)
        }
        tabs.marked = []
        return folder
    }

    // MARK: Moving

    /// Moves tabs into an existing group, at its end.
    func move(_ ids: [UUID], toGroup group: UUID, in tabs: SpaceTabs) {
        tabs.update { $0.add(ids, to: group) }
        tabs.marked = []
    }

    /// Moves tabs into one new window showing the same space, in their order; pinned tabs stay
    /// pinned.
    func moveToNewWindow(_ ids: [UUID], from tabs: SpaceTabs, in window: WindowState) {
        let ids = tabs.layout.ids.filter(ids.contains)
        guard let first = ids.first else { return }
        let pinned = Set(ids.filter { tabs.layout.isPinned($0) })
        moveToNewWindow(first, from: tabs, in: window)
        guard let created = windows.last, created !== window, created.spaces[tabs.spaceID] != nil else { return }
        for id in ids.dropFirst() {
            moveTab(id, from: (window, tabs.spaceID), to: (created, tabs.spaceID), before: nil, group: nil,
                    select: false, pinned: pinned.contains(id))
        }
        tabs.marked = []
    }
}
