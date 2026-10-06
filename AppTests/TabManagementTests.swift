import XCTest
@testable import iSmith

/// Pinned tabs, picking several tabs, the actions on them, sorting by site, the tab overview's
/// search, and saving pins and the vertical-tabs setting.
@MainActor
final class TabManagementTests: XCTestCase {
    private var ids: [UUID] = []

    override func setUp() {
        ids = (0..<6).map { _ in UUID() }
    }

    /// a b c d e f, nothing grouped, `a` selected.
    private func layout(_ count: Int = 6) -> TabLayout {
        var layout = TabLayout()
        for id in ids.prefix(count) { layout.insert(id) }
        layout.select(ids[0])
        return layout
    }

    /// Letters, with "*" for pinned and "[group]" for grouped tabs.
    private func names(_ layout: TabLayout) -> String {
        layout.ids.map { id in
            let letter = String(UnicodeScalar(UInt8(97 + ids.firstIndex(of: id)!)))
            if layout.isPinned(id) { return letter + "*" }
            guard let g = layout.groupID(of: id) else { return letter }
            return letter + "[" + (layout.group(g)?.name ?? "?") + "]"
        }.joined(separator: " ")
    }

    // MARK: Pinned tabs

    func testPinningMovesTabsToTheStartAndOutOfTheirGroups() {
        var l = layout()
        l.createGroup(with: [ids[1], ids[2]], name: "G")
        l.pin([ids[4], ids[2]])
        XCTAssertEqual(names(l), "c* e* a b[G] d f", "pinned tabs come first, in strip order, out of their group")
        XCTAssertEqual(l.pinnedCount, 2)
        XCTAssertEqual(l.items.prefix(2), [.pinned(ids[2]), .pinned(ids[4])])
        l.pin([ids[5]])
        XCTAssertEqual(names(l), "c* e* f* a b[G] d", "a newly pinned tab goes after the others")
        l.unpin([ids[2], ids[4]])
        XCTAssertEqual(names(l), "f* c e a b[G] d", "unpinned tabs go first among the unpinned ones")
    }

    func testDropsAndInsertsRespectThePinnedRun() {
        var l = layout()
        l.pin([ids[0], ids[1]])
        XCTAssertEqual(names(l), "a* b* c d e f")
        l.move(ids[4], before: ids[1], group: nil, pinned: true)
        XCTAssertEqual(names(l), "a* e* b* c d f", "a drop among the pinned tabs pins")
        l.move(ids[0], before: ids[3], group: nil)
        XCTAssertEqual(names(l), "e* b* c a d f", "a drop among the others unpins")
        l.move(ids[5], before: ids[4], group: nil)
        XCTAssertEqual(names(l), "e* b* f c a d", "an unpinned tab never lands among the pinned ones")
        l.insert(ids[3], after: ids[4])
        XCTAssertEqual(names(l), "e* b* f c a d", "inserting an existing tab changes nothing")
        let new = UUID()
        ids.append(new)
        l.insert(new, after: ids[4])
        XCTAssertEqual(names(l), "e* b* g f c a d", "a tab opened from a pinned tab goes first among the others")
        l.createGroup(with: [ids[1]], name: "H")
        XCTAssertEqual(names(l), "e* b[H] g f c a d", "grouping a pinned tab unpins it")
        l.addToAgentGroup(ids[4])
        XCTAssertFalse(l.isPinned(ids[4]), "an agent taking over a pinned tab unpins it")
    }

    func testRestoredLayoutsPutPinnedTabsFirst() {
        let g = TabGroup(name: "G", color: .blue)
        let l = TabLayout(slots: [.init(id: ids[0], group: nil), .init(id: ids[1], group: g.id, pinned: true),
                                  .init(id: ids[2], group: nil, pinned: true)],
                          groups: [g], selected: ids[1])
        XCTAssertEqual(names(l), "b* c* a", "pinned first; a pinned tab is never in a group")
        XCTAssertTrue(l.groups.isEmpty, "the group lost its only tab")
    }

    // MARK: Acting on several tabs

    func testCloseOthersAndToTheRightKeepPinnedTabs() {
        var l = layout()
        l.pin([ids[0]])
        XCTAssertEqual(l.others(than: [ids[2]]), [ids[1], ids[3], ids[4], ids[5]])
        XCTAssertEqual(l.tabsRight(of: [ids[1], ids[3]]), [ids[4], ids[5]])
        XCTAssertEqual(l.tabsRight(of: [ids[0]]), [ids[1], ids[2], ids[3], ids[4], ids[5]], "right of a pinned tab: every unpinned tab")
        XCTAssertEqual(l.tabsRight(of: [ids[5]]), [])
    }

    func testSortingBySiteKeepsPinsAndGroups() {
        var l = layout()
        l.pin([ids[4], ids[5]])
        l.createGroup(with: [ids[2], ids[3]], name: "G")
        XCTAssertEqual(names(l), "e* f* a b c[G] d[G]")
        let site: [UUID: String] = [ids[0]: "zeta.example", ids[1]: "alpha.example", ids[2]: "m.example",
                                    ids[3]: "b.example", ids[4]: "y.example", ids[5]: "x.example"]
        l.sort(l.ids) { site[$0]! }
        XCTAssertEqual(names(l), "f* e* b a d[G] c[G]", "each run sorts on its own")
        var one = layout()
        one.sort(one.run(of: ids[3])) { site[$0]! }
        XCTAssertEqual(names(one), "b d c f e a", "one tab sorts its whole run")
        // Ties keep their order, and sorting twice changes nothing.
        var ties = layout()
        ties.sort(ties.ids) { _ in "same" }
        XCTAssertEqual(names(ties), "a b c d e f")
    }

    func testSiteKeyIgnoresWWWAndCase() {
        let a = Tab(url: URL(string: "https://www.Contoso.com/x"), title: "B")
        let b = Tab(url: URL(string: "https://contoso.com/y"), title: "a")
        XCTAssertLessThan(BrowserState.siteKey(b), BrowserState.siteKey(a), "same site, then by title")
        XCTAssertTrue(BrowserState.siteKey(a).hasPrefix("contoso.com"))
    }

    // MARK: Picking several tabs

    func testCommandAndShiftClicksPickTabsConsistently() {
        var l = layout()
        var s = TabSelection()
        XCTAssertNil(s.click(ids[2], .command, in: l))
        XCTAssertNil(s.click(ids[4], .command, in: l))
        XCTAssertEqual(s.targets(for: ids[2], in: l), [ids[0], ids[2], ids[4]], "the selected tab is part of the selection")
        XCTAssertEqual(s.targets(for: ids[0], in: l), [ids[0], ids[2], ids[4]], "the selected tab's menu acts on all of them")
        XCTAssertEqual(s.targets(for: ids[1], in: l), [ids[1]], "a tab outside the selection acts alone")
        XCTAssertNil(s.click(ids[2], .command, in: l), "⌘-click again takes it out")
        XCTAssertEqual(s.marked, [ids[4]])
        // ⇧-click: from the anchor (the last tab clicked) to the clicked tab.
        XCTAssertNil(s.click(ids[1], .shift, in: l))
        XCTAssertEqual(s.marked, Set([ids[1], ids[2]]), "⇧-click picks the range alone")
        XCTAssertNil(s.click(ids[5], .commandShift, in: l))
        XCTAssertEqual(s.marked, Set(ids[1...5]), "⌘⇧-click adds a range")
        // ⌘-click on the selected tab hands the selection to the nearest picked tab.
        let next = s.click(ids[0], .command, in: l)
        XCTAssertEqual(next, ids[1])
        l.select(next)
        s.prune(l)
        XCTAssertEqual(s.targets(for: ids[1], in: l), Array(ids[1...5]))
        // A plain click on a picked tab keeps the selection; on any other tab it clears it.
        XCTAssertEqual(s.click(ids[3], .plain, in: l), ids[3])
        l.select(ids[3])
        s.prune(l)
        XCTAssertEqual(s.targets(for: ids[3], in: l), Array(ids[1...5]))
        XCTAssertEqual(s.click(ids[0], .plain, in: l), ids[0])
        XCTAssertTrue(s.marked.isEmpty)
    }

    func testShiftClickWithoutAnAnchorStartsAtTheSelectedTab() {
        var l = layout()
        l.select(ids[3])
        var s = TabSelection()
        _ = s.click(ids[1], .shift, in: l)
        XCTAssertEqual(s.targets(for: ids[2], in: l), [ids[1], ids[2], ids[3]])
        // Closing tabs drops them from the selection.
        l.remove(ids[2])
        s.prune(l)
        XCTAssertEqual(s.marked, [ids[1]])
    }

    func testSpaceTabsActionsOnTheSelection() async throws {
        let wired = try WiredBrowser()
        let browser = wired.browser
        let window = wired.window
        let tabs = wired.tabs
        browser.closeTabs(tabs.layout.ids, in: tabs)
        let opened = ["https://b.example/1", "https://a.example/1", "https://c.example/1", "https://a.example/2"].map {
            browser.openTab(in: window, space: wired.spaceID, url: nil, title: $0)
        }
        let all = opened.map(\.id)
        browser.selectTab(all[0], in: tabs)
        XCTAssertNil(tabs.click(all[2], .command))
        XCTAssertEqual(tabs.targets(for: all[2]), [all[0], all[2]])
        browser.pin(tabs.targets(for: all[2]), in: tabs)
        XCTAssertEqual(tabs.layout.pinnedIDs, [all[0], all[2]])
        XCTAssertTrue(tabs.selection.marked.isEmpty, "acting on the selection clears it")
        // ⌘W on a pinned tab selects the first unpinned tab instead of closing it.
        browser.selectTab(all[2], in: tabs)
        browser.closeSelectedTab(in: window)
        XCTAssertEqual(tabs.layout.count, 4, "a pinned tab isn't closed by ⌘W")
        XCTAssertEqual(tabs.layout.selected, all[1])
        browser.closeTabsRight(of: [all[1]], in: tabs)
        XCTAssertEqual(tabs.layout.ids, [all[0], all[2], all[1]])
        browser.duplicate([all[1], all[0]], in: tabs, window: window)
        XCTAssertEqual(tabs.layout.count, 5)
        XCTAssertEqual(tabs.layout.selected, all[1], "several copies open in the background")
        browser.closeOthers(than: [all[1]], in: tabs)
        XCTAssertEqual(tabs.layout.ids, [all[0], all[2], all[1]], "pinned tabs stay")
        await wired.tearDown()
    }

    // MARK: Overview search

    func testOverviewSearchMatchesTitleSiteAndGroupWords() {
        let group = TabGroup(name: "Storefront", color: .cyan)
        let entries = [
            TabSearchEntry(id: ids[0], title: "Inbox – Outlook", host: "outlook.office.com", group: nil, pinned: true, selected: true),
            TabSearchEntry(id: ids[1], title: "Café orders", host: "etsy.com", group: group, pinned: false, selected: false),
            TabSearchEntry(id: ids[2], title: "Pull requests", host: "github.com", group: nil, pinned: false, selected: false),
        ]
        XCTAssertEqual(TabSearch.filter(entries, query: "").map(\.id), [ids[0], ids[1], ids[2]])
        XCTAssertEqual(TabSearch.filter(entries, query: "OUTLOOK").map(\.id), [ids[0]])
        XCTAssertEqual(TabSearch.filter(entries, query: "cafe").map(\.id), [ids[1]], "accents don't matter")
        XCTAssertEqual(TabSearch.filter(entries, query: "store etsy").map(\.id), [ids[1]], "group names count; every word must match")
        XCTAssertEqual(TabSearch.filter(entries, query: "github pull").map(\.id), [ids[2]])
        XCTAssertTrue(TabSearch.filter(entries, query: "store github").isEmpty)
    }

    // MARK: Saving

    func testPinsAndVerticalTabsAreSavedAndRestored() throws {
        let tabs = SpaceTabs(spaceID: "contoso")
        let made = (0..<3).map { Tab(url: URL(string: "https://example.com/\($0)"), title: "T\($0)") }
        for tab in made { tabs.add(tab) { $0.insert(tab.id) } }
        tabs.update { $0.pin([made[2].id]) }
        let window = WindowState(activeSpaceID: "contoso")
        window.verticalTabs = true
        window.setTabs(tabs)
        let record = window.record(spaceOrder: ["contoso"])
        XCTAssertEqual(record.verticalTabs, true)
        let data = try JSONEncoder().encode(SessionFile(windows: [record]))
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(json.components(separatedBy: "\"pinned\"").count - 1, 1, "only pinned tabs write the field")
        let loaded = try JSONDecoder().decode(SessionFile.self, from: data)
        XCTAssertEqual(loaded.windows.first?.verticalTabs, true)
        let restored = SpaceTabs.restore(try XCTUnwrap(loaded.windows.first?.spaces.first))
        XCTAssertEqual(restored.layout.pinnedIDs, [made[2].id])
        XCTAssertEqual(restored.layout.ids, [made[2].id, made[0].id, made[1].id])
        // Older files: no field means not pinned, and the window follows the default.
        let old = try JSONDecoder().decode(WindowRecord.self, from: Data(#"{"spaces":[]}"#.utf8))
        XCTAssertNil(old.verticalTabs)
    }

    func testRestoredWindowKeepsItsTabLayoutStyle() async throws {
        let wired = try WiredBrowser()
        let record = WindowRecord(id: UUID(), frame: nil, activeSpace: wired.spaceID, spaces: [
            SpaceRecord(space: wired.spaceID, selected: nil, groups: [],
                        tabs: [TabRecord(id: UUID(), url: nil, title: "x", group: nil, keepAlive: nil, pinned: true)]),
        ], verticalTabs: true)
        let window = wired.browser.restoreWindow(record)
        XCTAssertTrue(window.verticalTabs)
        XCTAssertEqual(window.active?.layout.pinnedCount, 1)
        XCTAssertEqual(wired.browser.sessionSnapshot.windows.first?.verticalTabs, true)
        await wired.tearDown()
    }
}
