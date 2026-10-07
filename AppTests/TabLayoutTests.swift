import XCTest
@testable import iSmith

/// The tab strip's rules: order, groups as single runs, selection, collapse and drops.
final class TabLayoutTests: XCTestCase {
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

    private func names(_ layout: TabLayout) -> String {
        layout.ids.map { id in
            let letter = String(UnicodeScalar(UInt8(97 + ids.firstIndex(of: id)!)))
            guard let g = layout.groupID(of: id) else { return letter }
            return letter + "[" + (layout.group(g)?.name ?? "?") + "]"
        }.joined(separator: " ")
    }

    func testInsertAndRemoveKeepOrderAndPickTheNextSelection() {
        var l = layout()
        XCTAssertEqual(names(l), "a b c d e f")
        l.select(ids[2])
        l.remove(ids[2])
        XCTAssertEqual(l.selected, ids[3], "closing the selected tab selects the one to its right")
        l.select(ids[5])
        l.remove(ids[5])
        XCTAssertEqual(l.selected, ids[4], "closing the last tab selects the one to its left")
        l.remove(ids[1])
        XCTAssertEqual(l.selected, ids[4], "closing another tab keeps the selection")
        for id in l.ids { l.remove(id) }
        XCTAssertNil(l.selected)
        XCTAssertTrue(l.isEmpty)
    }

    func testInsertBeforeAnchorAndAfterOpener() {
        var l = layout(3)
        l.insert(ids[3], before: ids[1])
        XCTAssertEqual(names(l), "a d b c")
        let g = l.createGroup(with: [ids[1], ids[2]], name: "G")!
        l.insert(ids[4], after: ids[1])
        XCTAssertEqual(names(l), "a d b[G] e[G] c[G]", "a tab opened from a grouped tab joins its group, next to it")
        l.insert(ids[5], group: g)
        XCTAssertEqual(names(l), "a d b[G] e[G] c[G] f[G]", "a new tab in a group goes to the group's end")
        l.insert(ids[0])
        XCTAssertEqual(l.count, 6, "inserting a tab that's already there does nothing")
    }

    func testCreateGroupGathersTabsAtTheLeftmostOne() {
        var l = layout()
        l.createGroup(with: [ids[4], ids[1], ids[3]], name: "Work", color: .cyan)
        XCTAssertEqual(names(l), "a b[Work] d[Work] e[Work] c f", "members keep their order and form one run")
        XCTAssertEqual(l.groups.first?.color, .cyan)
        XCTAssertNil(l.createGroup(with: [UUID()]), "unknown tabs make no group")
    }

    func testMoveGroupMovesTheWholeRunAndNeverSplitsAnother() {
        var l = layout()
        let work = l.createGroup(with: [ids[1], ids[2]], name: "Work")!
        l.createGroup(with: [ids[4], ids[5]], name: "Home")
        XCTAssertEqual(names(l), "a b[Work] c[Work] d e[Home] f[Home]")
        l.moveGroup(work, before: nil)
        XCTAssertEqual(names(l), "a d e[Home] f[Home] b[Work] c[Work]", "to the end, tabs in order")
        l.moveGroup(work, before: ids[0])
        XCTAssertEqual(names(l), "b[Work] c[Work] a d e[Home] f[Home]", "to the front")
        l.moveGroup(work, before: ids[5])
        XCTAssertEqual(names(l), "a d b[Work] c[Work] e[Home] f[Home]", "before a tab inside another group: before that group")
        l.moveGroup(work, before: ids[2])
        XCTAssertEqual(names(l), "a d b[Work] c[Work] e[Home] f[Home]", "before one of its own tabs: nothing moves")
        l.pin([ids[0]])
        l.moveGroup(work, before: ids[0])
        XCTAssertEqual(names(l), "a b[Work] c[Work] d e[Home] f[Home]", "never among the pinned tabs")
        XCTAssertTrue(l.isPinned(ids[0]))
    }

    func testNextColorSkipsUsedColors() {
        var l = layout()
        XCTAssertEqual(l.nextColor, .blue)
        l.createGroup(with: [ids[0]])
        XCTAssertEqual(l.groups[0].color, .blue)
        l.createGroup(with: [ids[1]])
        XCTAssertEqual(l.groups.map(\.color), [.blue, .red])
    }

    func testMoveWithinStripAndIntoAndOutOfGroups() {
        var l = layout()
        let g = l.createGroup(with: [ids[1], ids[2]], name: "G")!
        // Drag f before b, into the group.
        l.move(ids[5], before: ids[1], group: g)
        XCTAssertEqual(names(l), "a f[G] b[G] c[G] d e")
        // Drag a to the end, ungrouped.
        l.move(ids[0], before: nil, group: nil)
        XCTAssertEqual(names(l), "f[G] b[G] c[G] d e a")
        // Drag b out of the group, just after it.
        l.move(ids[1], before: ids[3], group: nil)
        XCTAssertEqual(names(l), "f[G] c[G] b d e a")
        // Drop onto itself with another group: only the membership changes.
        l.move(ids[1], before: ids[1], group: g)
        XCTAssertEqual(names(l), "f[G] c[G] b[G] d e a")
        // A drop that would split a group gathers the group back into one run.
        let h = l.createGroup(with: [ids[3], ids[4]], name: "H")!
        l.move(ids[0], before: ids[2], group: h)
        XCTAssertEqual(names(l), "f[G] c[G] b[G] d[H] e[H] a[H]",
                       "an anchor outside the group puts the tab at the group's end, and G stays whole")
        for group in l.groups {
            let positions = l.tabs(in: group.id).compactMap { l.index(of: $0) }
            XCTAssertEqual(positions, Array(positions.first!...positions.last!), "\(group.name) is one run")
        }
        // A move to an unknown group is a move out of any group.
        l.move(ids[0], before: nil, group: UUID())
        XCTAssertNil(l.groupID(of: ids[0]))
    }

    func testEmptyGroupsDisappear() {
        var l = layout()
        let g = l.createGroup(with: [ids[1]], name: "G")!
        l.remove(ids[1])
        XCTAssertNil(l.group(g), "a group with no tabs is removed")
        let h = l.createGroup(with: [ids[2], ids[3]], name: "H")!
        l.move(ids[2], before: nil, group: nil)
        l.move(ids[3], before: nil, group: nil)
        XCTAssertNil(l.group(h), "dragging every tab out removes the group")
    }

    func testAddToGroupRemoveFromGroupAndUngroup() {
        var l = layout()
        let g = l.createGroup(with: [ids[1], ids[2]], name: "G")!
        l.add([ids[5], ids[0]], to: g)
        XCTAssertEqual(names(l), "b[G] c[G] a[G] f[G] d e")
        l.removeFromGroup([ids[2], ids[0]])
        XCTAssertEqual(names(l), "b[G] f[G] c a d e", "removed tabs land just after the group, in order")
        l.ungroup(g)
        XCTAssertEqual(names(l), "b f c a d e", "ungrouping leaves tabs in place")
        XCTAssertTrue(l.groups.isEmpty)
    }

    func testRenameAndRecolor() {
        var l = layout()
        let g = l.createGroup(with: [ids[0]], name: "")!
        l.rename(g, to: "Mail")
        l.setColor(g, .orange)
        XCTAssertEqual(l.group(g)?.name, "Mail")
        XCTAssertEqual(l.group(g)?.color, .orange)
    }

    func testCollapseHidesTabsAndMovesTheSelectionOut() {
        var l = layout()
        let g = l.createGroup(with: [ids[1], ids[2]], name: "G")!
        l.select(ids[2])
        XCTAssertTrue(l.setCollapsed(g, true))
        XCTAssertEqual(l.selected, ids[3], "the nearest tab to the right of the group is selected")
        XCTAssertEqual(l.items, [.tab(ids[0], group: nil), .group(l.group(g)!, count: 2),
                                 .tab(ids[3], group: nil), .tab(ids[4], group: nil), .tab(ids[5], group: nil)])
        // Selecting a tab inside a collapsed group expands it (⌃Tab into the group).
        l.select(ids[1])
        XCTAssertEqual(l.group(g)?.collapsed, false)
        // Every tab in the group: collapsing needs a new tab first.
        var only = layout(2)
        let all = only.createGroup(with: [ids[0], ids[1]])!
        only.select(ids[0])
        XCTAssertFalse(only.setCollapsed(all, true))
        XCTAssertEqual(only.group(all)?.collapsed, false, "nothing changes until there's a tab to select")
        only.insert(ids[2])
        only.select(ids[2])
        XCTAssertTrue(only.setCollapsed(all, true))
    }

    func testReopeningIntoAGroupWhoseNeighborMovedKeepsTheGroupInPlace() {
        // [G: a b] c d; b is closed remembering "before c, in G"; then c is dragged to the front.
        var l = layout(4)
        let g = l.createGroup(with: [ids[0], ids[1]], name: "G")!
        l.remove(ids[1])
        l.move(ids[2], before: ids[0], group: nil)
        XCTAssertEqual(names(l), "c a[G] d")
        l.insert(ids[1], before: ids[2], group: g)
        XCTAssertEqual(names(l), "c a[G] b[G] d", "the tab rejoins its group at the end; the group doesn't move")
        l.insert(ids[4], before: ids[1], group: g)
        XCTAssertEqual(names(l), "c a[G] e[G] b[G] d", "an anchor inside the group is used")
    }

    func testSelectingAGoneTabKeepsTheSelection() {
        var l = layout(3)
        l.select(ids[1])
        l.select(UUID())
        XCTAssertEqual(l.selected, ids[1])
        l.select(nil)
        XCTAssertNil(l.selected, "only an explicit nil clears it")
    }

    func testNeighborWraps() {
        let l = layout(3)
        XCTAssertEqual(l.neighbor(of: ids[2], forward: true), ids[0])
        XCTAssertEqual(l.neighbor(of: ids[0], forward: false), ids[2])
        XCTAssertEqual(l.neighbor(of: ids[1], forward: true), ids[2])
        XCTAssertNil(layout(1).neighbor(of: ids[0], forward: true))
    }

    func testRebuildingFromSavedRecordsRepairsThem() {
        let g = TabGroup(name: "G", color: .green)
        let stranger = UUID()
        let repaired = TabLayout(slots: [.init(id: ids[0], group: g.id), .init(id: ids[1], group: nil),
                                         .init(id: ids[2], group: g.id), .init(id: ids[3], group: stranger),
                                         .init(id: ids[0], group: nil)],
                                 groups: [g, g, TabGroup(name: "Empty", color: .red)], selected: UUID())
        XCTAssertEqual(repaired.ids, [ids[0], ids[2], ids[1], ids[3]], "duplicates dropped, the group made one run")
        XCTAssertEqual(repaired.groups.map(\.name), ["G"], "duplicate and empty groups dropped")
        XCTAssertNil(repaired.groupID(of: ids[3]), "a tab in an unknown group is ungrouped")
        XCTAssertEqual(repaired.selected, ids[0], "a missing selection falls back to the first tab")
    }
}
