@testable import BrowserData
import XCTest

/// Bookmarks (one tree for every space): roots, ordering, moves, copies, deletes, search, URL
/// lookup and import.
final class BookmarkStoreTests: XCTestCase {
    private var db: BrowserDatabase!
    private var store: BookmarkStore { db.bookmarks }

    override func setUpWithError() throws {
        db = try BrowserDatabase.inMemory()
    }

    private func titles(_ folder: Int64) throws -> [String] {
        try store.children(of: folder).map(\.title)
    }

    /// Every folder has positions 0..<n.
    private func assertDense(file: StaticString = #filePath, line: UInt = #line) throws {
        func check(_ trees: [BookmarkTree]) {
            XCTAssertEqual(trees.map(\.bookmark.position), Array(0..<trees.count), file: file, line: line)
            for t in trees { check(t.children) }
        }
        for root in try store.tree() { check(root.children) }
    }

    func testRootsAreCreatedLazilyOnce() throws {
        let bar = try store.root(.bar)
        XCTAssertEqual(bar.title, "Bookmarks Bar")
        XCTAssertEqual(bar.root, .bar)
        XCTAssertNil(bar.parentID)
        XCTAssertTrue(bar.isFolder)
        XCTAssertEqual(try store.root(.bar), bar, "same root the second time")
        XCTAssertNotEqual(try store.root(.other).id, bar.id)
        let tree = try store.tree()
        XCTAssertEqual(tree.map(\.bookmark.root), [.bar, .other])
        XCTAssertEqual(tree.map(\.bookmark.title), ["Bookmarks Bar", "Other Bookmarks"])
    }

    func testAddOrdersAndKeepsPositionsDense() throws {
        let bar = try store.root(.bar)
        try store.add(parent: nil, title: "B", url: "https://b.com")
        try store.add(parent: bar.id, title: "D", url: "https://d.com")
        try store.add(parent: nil, title: "A", url: "https://a.com", at: 0)
        try store.add(parent: nil, title: "C", url: "https://c.com", at: 2)
        try store.add(parent: nil, title: "E", url: "javascript:alert(1)", at: 99)
        let folder = try store.addFolder(parent: nil, title: "F", at: -5)
        XCTAssertEqual(try titles(bar.id), ["F", "A", "B", "C", "D", "E"])
        XCTAssertEqual(try store.children(of: bar.id).last?.url, "javascript:alert(1)", "kept as given")
        try store.add(parent: folder.id, title: "inside", url: "https://in.com")
        XCTAssertEqual(try titles(folder.id), ["inside"])
        try assertDense()

        let leaf = try store.children(of: bar.id)[1]
        XCTAssertThrowsError(try store.add(parent: leaf.id, title: "x", url: "https://x.com")) {
            XCTAssertEqual($0 as? BrowserDataError, .notAFolder)
        }
    }

    func testUpdate() throws {
        let b = try store.add(parent: nil, title: "Old", url: "https://old.com")
        try store.update(b.id, title: "New", url: nil)
        var now = try XCTUnwrap(try store.bookmark(id: b.id))
        XCTAssertEqual(now.title, "New")
        XCTAssertEqual(now.url, "https://old.com")
        XCTAssertNotNil(now.dateModified)
        try store.update(b.id, title: nil, url: "https://new.com")
        now = try XCTUnwrap(try store.bookmark(id: b.id))
        XCTAssertEqual(now.url, "https://new.com")
        XCTAssertEqual(try store.search("new", limit: 10).map(\.id), [b.id])

        let f = try store.addFolder(parent: nil, title: "F")
        XCTAssertThrowsError(try store.update(f.id, title: nil, url: "https://x.com")) {
            XCTAssertEqual($0 as? BrowserDataError, .notABookmark)
        }
        XCTAssertThrowsError(try store.update(try store.root(.bar).id, title: "Renamed", url: nil)) {
            XCTAssertEqual($0 as? BrowserDataError, .cannotModifyRoot)
        }
        XCTAssertThrowsError(try store.update(9999, title: "x", url: nil)) {
            XCTAssertEqual($0 as? BrowserDataError, .notFound)
        }
    }

    func testMoveReordersWithDragAndDropIndexes() throws {
        let bar = try store.root(.bar)
        let ids = try ["A", "B", "C", "D"].map { try store.add(parent: nil, title: $0, url: "https://\($0).com").id }
        try store.move(ids[0], to: bar.id, at: 4)       // A to the end
        XCTAssertEqual(try titles(bar.id), ["B", "C", "D", "A"])
        try store.move(ids[0], to: bar.id, at: 0)       // back to the front
        XCTAssertEqual(try titles(bar.id), ["A", "B", "C", "D"])
        try store.move(ids[0], to: bar.id, at: 1)       // dropping just after itself: no change
        XCTAssertEqual(try titles(bar.id), ["A", "B", "C", "D"])
        try store.move(ids[0], to: bar.id, at: 2)       // between B and C
        XCTAssertEqual(try titles(bar.id), ["B", "A", "C", "D"])
        try store.move(ids[3], to: bar.id, at: 1)       // D up
        XCTAssertEqual(try titles(bar.id), ["B", "D", "A", "C"])
        try store.move(ids[1], to: bar.id, at: nil)     // B appended
        XCTAssertEqual(try titles(bar.id), ["D", "A", "C", "B"])
        try assertDense()

        let other = try store.root(.other)
        try store.move(ids[2], to: other.id, at: 0)
        XCTAssertEqual(try titles(bar.id), ["D", "A", "B"])
        XCTAssertEqual(try titles(other.id), ["C"])
        XCTAssertEqual(try store.bookmark(id: ids[2])?.parentID, other.id)
        try assertDense()
    }

    func testMoveCarriesTheSubtree() throws {
        let folder = try store.addFolder(parent: nil, title: "Work stuff")
        let sub = try store.addFolder(parent: folder.id, title: "Sub")
        let leaf = try store.add(parent: sub.id, title: "Leaf", url: "https://leaf.com")
        try store.add(parent: nil, title: "Stays", url: "https://stays.com")
        let other = try store.root(.other)
        try store.move(folder.id, to: other.id, at: 0)
        XCTAssertEqual(try titles(other.id), ["Work stuff"])
        XCTAssertEqual(try store.bookmark(id: leaf.id)?.parentID, sub.id)
        XCTAssertEqual(try titles(try store.root(.bar).id), ["Stays"])
        try assertDense()
    }

    func testMoveRefusesCyclesAndRoots() throws {
        let a = try store.addFolder(parent: nil, title: "A")
        let b = try store.addFolder(parent: a.id, title: "B")
        let bar = try store.root(.bar)
        let other = try store.root(.other)
        XCTAssertThrowsError(try store.move(a.id, to: a.id, at: nil)) { XCTAssertEqual($0 as? BrowserDataError, .wouldCreateCycle) }
        XCTAssertThrowsError(try store.move(a.id, to: b.id, at: nil)) { XCTAssertEqual($0 as? BrowserDataError, .wouldCreateCycle) }
        XCTAssertThrowsError(try store.move(bar.id, to: other.id, at: nil)) { XCTAssertEqual($0 as? BrowserDataError, .cannotModifyRoot) }
        let leaf = try store.add(parent: nil, title: "L", url: "https://l.com")
        XCTAssertThrowsError(try store.move(a.id, to: leaf.id, at: nil)) { XCTAssertEqual($0 as? BrowserDataError, .notAFolder) }
        XCTAssertEqual(try store.bookmark(id: a.id)?.parentID, bar.id, "nothing changed")
        try assertDense()
    }

    func testCopyIsDeep() throws {
        let folder = try store.addFolder(parent: nil, title: "F")
        let sub = try store.addFolder(parent: folder.id, title: "Sub")
        try store.add(parent: sub.id, title: "Leaf", url: "https://leaf.com")
        try store.add(parent: folder.id, title: "Top", url: "https://top.com")

        let other = try store.root(.other)
        let copy = try store.copy(folder.id, to: other.id, at: nil)
        XCTAssertNotEqual(copy.id, folder.id)
        let tree = try XCTUnwrap(try store.tree().last?.children.first)
        XCTAssertEqual(tree.bookmark.title, "F")
        XCTAssertEqual(tree.children.map(\.bookmark.title), ["Sub", "Top"])
        XCTAssertEqual(tree.children[0].children.map(\.bookmark.url), ["https://leaf.com"])
        XCTAssertEqual(try store.bookmarks(url: "https://leaf.com").count, 2, "original stays")

        // Copying a folder into itself copies what was there, once.
        try store.copy(folder.id, to: folder.id, at: 0)
        XCTAssertEqual(try titles(folder.id), ["F", "Sub", "Top"])
        try assertDense()
    }

    func testDeleteIsRecursiveAndRootsStay() throws {
        let bar = try store.root(.bar)
        try store.add(parent: nil, title: "A", url: "https://a.com")
        let folder = try store.addFolder(parent: nil, title: "F")
        let leaf = try store.add(parent: folder.id, title: "Leaf", url: "https://leaf.com")
        try store.add(parent: nil, title: "C", url: "https://c.com")
        try store.delete(folder.id)
        XCTAssertEqual(try titles(bar.id), ["A", "C"])
        XCTAssertNil(try store.bookmark(id: leaf.id))
        try assertDense()
        XCTAssertThrowsError(try store.delete(bar.id)) { XCTAssertEqual($0 as? BrowserDataError, .cannotModifyRoot) }
        XCTAssertThrowsError(try store.delete(folder.id)) { XCTAssertEqual($0 as? BrowserDataError, .notFound) }
    }

    func testSearchAndURLLookup() throws {
        try store.add(parent: nil, title: "Swift Forums", url: "https://forums.swift.org")
        try store.add(parent: nil, title: "GitHub", url: "https://github.com/apple/swift")
        try store.add(parent: nil, title: "Azure DevOps", url: "https://dev.azure.com/contoso-dev")
        try store.add(parent: nil, title: "GitHub again", url: "https://github.com/apple/swift")
        try store.addFolder(parent: nil, title: "Swift folder")

        XCTAssertEqual(try store.search("swift", limit: 10).map(\.title), ["GitHub again", "GitHub", "Swift Forums"],
                       "newest first, folders excluded")
        XCTAssertEqual(try store.search("APPLE github", limit: 10).count, 2)
        XCTAssertEqual(try store.search("azure devops", limit: 10).map(\.title), ["Azure DevOps"])
        XCTAssertEqual(try store.search("", limit: 10), [])
        XCTAssertEqual(try store.search("github", limit: 1).count, 1)

        XCTAssertEqual(try store.bookmarks(url: "https://github.com/apple/swift").map(\.title), ["GitHub", "GitHub again"])
        XCTAssertEqual(try store.bookmarks(url: "https://github.com/apple/swift/"), [], "exact match only")
    }

    func testImportNestedIdempotentAndMerging() throws {
        let bar = try store.root(.bar)
        let other = try store.root(.other)
        let added = Date(timeIntervalSince1970: 1_600_000_000)
        let barNodes = [
            BookmarkImportNode(title: "Mail", url: "https://mail.example.com", dateAdded: added, externalID: "g1"),
            BookmarkImportNode(title: "Dev", url: nil, children: [
                BookmarkImportNode(title: "Repo", url: "https://github.com/scott/repo", externalID: "g3"),
                BookmarkImportNode(title: "Deeper", url: nil, children: [
                    BookmarkImportNode(title: "Docs", url: "https://docs.swift.org", externalID: "g5"),
                ], externalID: "g4"),
            ], externalID: "g2"),
            BookmarkImportNode(title: "No id", url: "https://noid.example.com"),
        ]
        let mobile = BookmarkImportNode(title: "Mobile Bookmarks", url: nil, children: [
            BookmarkImportNode(title: "Phone", url: "https://phone.example.com", externalID: "m1"),
        ], externalID: "mobile-root")

        var result = try store.importTree(barNodes, into: bar.id)
        XCTAssertEqual(result, BookmarkImportResult(bookmarksAdded: 4, foldersAdded: 2))
        result = try store.importTree([mobile], into: other.id)
        XCTAssertEqual(result, BookmarkImportResult(bookmarksAdded: 1, foldersAdded: 1))

        let tree = try store.tree()
        XCTAssertEqual(tree[0].children.map(\.bookmark.title), ["Mail", "Dev", "No id"])
        XCTAssertEqual(tree[0].children[1].children.map(\.bookmark.title), ["Repo", "Deeper"])
        XCTAssertEqual(tree[0].children[1].children[1].children.map(\.bookmark.url), ["https://docs.swift.org"])
        XCTAssertEqual(tree[0].children[0].bookmark.dateAdded, added)
        XCTAssertEqual(tree[0].children[0].bookmark.externalID, "g1")
        XCTAssertEqual(tree[1].children.map(\.bookmark.title), ["Mobile Bookmarks"])

        // Again, with one new bookmark inside an existing folder: only that is added.
        var again = barNodes
        again[1].children[1].children.append(BookmarkImportNode(title: "New", url: "https://new.example.com", externalID: "g6"))
        result = try store.importTree(again, into: bar.id)
        XCTAssertEqual(result, BookmarkImportResult(bookmarksAdded: 2, foldersAdded: 0, foldersMerged: 2, skipped: 3),
                       "the id-less bookmark is added again; Dev and Deeper are merged into")
        let deeper = try store.tree()[0].children[1].children[1]
        XCTAssertEqual(deeper.children.map(\.bookmark.title), ["Docs", "New"])
        try assertDense()

        // Into another folder: items already anywhere in the tree aren't added again.
        result = try store.importTree(barNodes, into: other.id)
        XCTAssertEqual(result.bookmarksAdded, 1, "only the id-less one")
        XCTAssertEqual(result.skipped, 3, "Mail, Repo and Docs; Dev and Deeper are merged into")
    }

    func testImportIntoABookmarkFails() throws {
        let bar = try store.root(.bar)
        let leaf = try store.add(parent: nil, title: "Leaf", url: "https://leaf.com")
        XCTAssertThrowsError(try store.importTree([BookmarkImportNode(title: "x", url: "https://x.com")], into: leaf.id))
        XCTAssertEqual(try titles(bar.id), ["Leaf"])
    }

    func testRemoveSpaceKeepsBookmarks() throws {
        try store.add(parent: nil, title: "A", url: "https://a.com")
        try db.history.recordVisit(space: "gone", url: URL(string: "https://a.com")!, title: "A")
        try db.sites.setZoom(1.5, host: "a.com")
        try db.removeSpace("gone")
        XCTAssertEqual(try db.history.visits(space: "gone", matching: "", limit: 10), [])
        XCTAssertEqual(try store.search("a.com", limit: 10).count, 1, "bookmarks belong to every space")
        XCTAssertEqual(try db.sites.zoom(host: "a.com"), 1.5, "site settings are global")
    }

    func testDidChangeIsPostedWithoutSpaces() throws {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
        let posted = expectation(forNotification: BookmarkStore.didChange, object: store) { note in
            note.userInfo?[BrowserDatabase.spacesKey] == nil
        }
        try store.add(parent: nil, title: "A", url: "https://a.com")
        wait(for: [posted], timeout: 2)
    }
}
