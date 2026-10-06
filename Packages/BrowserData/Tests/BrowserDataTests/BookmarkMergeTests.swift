@testable import BrowserData
import GRDB
import XCTest

/// "v3-global-bookmarks": per-space bookmark trees in an old database become one tree, with a
/// backup of the file made first.
final class BookmarkMergeTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL { BrowserDatabase.defaultFileURL(dataDirectory: dir) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BookmarkMergeTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("iSmith", isDirectory: true)
        try SecureFile.prepareDirectory(dir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    // MARK: An old database

    /// Writes per-space bookmarks with the schema before v3, as the app did.
    private final class OldBookmarks {
        let db: Database
        private var roots: [String: Int64] = [:]
        private var stamp = 1_700_000_000.0
        init(_ db: Database) { self.db = db }

        func root(_ space: String, _ root: BookmarkRoot) throws -> Int64 {
            if let id = roots["\(space)/\(root.rawValue)"] { return id }
            try db.execute(sql: """
                INSERT INTO bookmark (space, parentID, isFolder, title, url, search, position, dateAdded, root)
                VALUES (?, NULL, 1, ?, NULL, '', ?, 0, ?)
                """, arguments: [space, root.title, root == .bar ? 0 : 1, root.rawValue])
            roots["\(space)/\(root.rawValue)"] = db.lastInsertedRowID
            return db.lastInsertedRowID
        }

        @discardableResult
        func add(_ space: String, _ parent: Int64, _ title: String, url: String? = nil, ext: String? = nil) throws -> Int64 {
            let position = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark WHERE parentID = ?", arguments: [parent]) ?? 0
            stamp += 1
            try db.execute(sql: """
                INSERT INTO bookmark (space, parentID, isFolder, title, url, search, position, dateAdded, externalID)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [space, parent, url == nil, title, url, (title + "\n" + (url ?? "")).lowercased(),
                                 position, stamp, ext])
            return db.lastInsertedRowID
        }

        func bar(_ space: String) throws -> Int64 { try root(space, .bar) }
        func other(_ space: String) throws -> Int64 { try root(space, .other) }
    }

    private func makeOldDatabase(_ build: (OldBookmarks) throws -> Void) throws {
        try SecureFile.ensureOwnerOnlyFile(dbURL)
        let queue = try DatabaseQueue(path: dbURL.path)
        try BrowserDatabase.migrator.migrate(queue, upTo: "v2-agent")
        try queue.write { db in try build(OldBookmarks(db)) }
        try queue.close()
    }

    /// The Brave import used in the user's case, 507 bookmarks: 7 on the bar and 10 folders of 50.
    private func braveImport(_ old: OldBookmarks, space: String) throws {
        let bar = try old.bar(space)
        for i in 0..<7 { try old.add(space, bar, "Bar \(i)", url: "https://bar\(i).example/", ext: "bar-\(i)") }
        let other = try old.other(space)
        for f in 0..<10 {
            let folder = try old.add(space, other, "Folder \(f)", ext: "folder-\(f)")
            for i in 0..<50 { try old.add(space, folder, "Item \(f).\(i)", url: "https://f\(f).example/\(i)", ext: "item-\(f)-\(i)") }
        }
    }

    private func outline(_ nodes: [BookmarkTree]) -> [String] {
        nodes.map { $0.bookmark.isFolder ? "\($0.bookmark.title)/[\(outline($0.children).joined(separator: ","))]" : $0.bookmark.title }
    }

    private func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("browser.before-global-bookmarks-") && $0.pathExtension == "sqlite" }
    }

    private func assertDense(_ db: BrowserDatabase, file: StaticString = #filePath, line: UInt = #line) throws {
        func check(_ trees: [BookmarkTree]) {
            XCTAssertEqual(trees.map(\.bookmark.position), Array(0..<trees.count), file: file, line: line)
            for t in trees { check(t.children) }
        }
        let tree = try db.bookmarks.tree()
        XCTAssertEqual(tree.map(\.bookmark.position), [0, 1], file: file, line: line)
        for root in tree { check(root.children) }
    }

    // MARK: Tests

    func testThreeIdenticalCopiesBecomeOne() throws {
        try makeOldDatabase { old in
            for space in ["contoso", "fabrikam", "home"] { try braveImport(old, space: space) }
        }
        let db = try BrowserDatabase(fileURL: dbURL)
        let counts = try db.writer.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark WHERE isFolder = 0") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark WHERE isFolder = 1 AND root IS NULL") ?? 0,
             try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark WHERE root IS NOT NULL") ?? 0)
        }
        XCTAssertEqual(counts.0, 507)
        XCTAssertEqual(counts.1, 10)
        XCTAssertEqual(counts.2, 2, "one Bookmarks Bar, one Other Bookmarks")
        let tree = try db.bookmarks.tree()
        XCTAssertEqual(tree[0].children.map(\.bookmark.title), (0..<7).map { "Bar \($0)" })
        XCTAssertEqual(tree[1].children.map(\.bookmark.title), (0..<10).map { "Folder \($0)" })
        XCTAssertEqual(tree[1].children[3].children.map(\.bookmark.title), (0..<50).map { "Item 3.\($0)" })
        try assertDense(db)
        let columns = try db.writer.read { try $0.columns(in: "bookmark").map(\.name) }
        XCTAssertFalse(columns.contains("space"))
        // Every row left is the first space's (the counts tie, so "contoso", the first space id): its ids are kept.
        let maxID = try db.writer.read { try Int64.fetchOne($0, sql: "SELECT MAX(id) FROM bookmark") }
        XCTAssertEqual(maxID, 519, "2 roots + 517 items of the first copy")
    }

    func testBackupIsMadeFirstAndOwnerOnly() throws {
        try makeOldDatabase { old in
            for space in ["contoso", "fabrikam"] { try braveImport(old, space: space) }
        }
        _ = try BrowserDatabase(fileURL: dbURL)
        let found = try backups()
        XCTAssertEqual(found.count, 1)
        let backup = try XCTUnwrap(found.first)
        let mode = try (FileManager.default.attributesOfItem(atPath: backup.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        // The copy is the database as it was: per space, both copies.
        let queue = try DatabaseQueue(path: backup.path)
        let (rows, hasSpace, applied) = try queue.read { db in
            (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark WHERE isFolder = 0") ?? 0,
             try db.columns(in: "bookmark").contains { $0.name == "space" },
             try BrowserDatabase.migrator.appliedMigrations(db))
        }
        try queue.close()
        XCTAssertEqual(rows, 1014)
        XCTAssertTrue(hasSpace)
        XCTAssertEqual(applied, ["v1", "v2-agent"])

        // Opening again doesn't merge or back up again.
        let again = try BrowserDatabase(fileURL: dbURL)
        XCTAssertEqual(try backups().count, 1)
        XCTAssertEqual(try again.bookmarks.search("example", limit: 2000).count, 507)
    }

    func testDifferingCopiesKeepEverythingInTheRightFolder() throws {
        try makeOldDatabase { old in
            // "alpha" and "gamma" have the most items (9), so "alpha" (the first id) is the primary tree
            // and "gamma" is folded in before "beta" (7).
            let a = try old.bar("alpha")
            try old.add("alpha", a, "X", url: "https://x.example/", ext: "gx")
            let f = try old.add("alpha", a, "F", ext: "gf")
            try old.add("alpha", f, "a1", url: "https://a1.example/", ext: "ga1")
            try old.add("alpha", f, "a2", url: "https://a2.example/", ext: "ga2")
            try old.add("alpha", a, "Y", url: "https://y.example/")
            let plain = try old.add("alpha", a, "Plain")
            try old.add("alpha", plain, "p1", url: "https://p1.example/")
            try old.add("alpha", plain, "same", url: "https://same.example/")
            try old.add("alpha", plain, "same", url: "https://same.example/")
            _ = try old.other("alpha")

            // "beta": the same folder F (by id) with a bookmark only it has, between the two
            // shared ones; a bookmark and a folder only it has.
            let b = try old.bar("beta")
            let bf = try old.add("beta", b, "F renamed", ext: "gf")
            try old.add("beta", bf, "a1", url: "https://a1.example/", ext: "ga1")
            try old.add("beta", bf, "b only", url: "https://b.example/", ext: "gb")
            try old.add("beta", bf, "a2", url: "https://a2.example/", ext: "ga2")
            try old.add("beta", b, "Z", url: "https://z.example/")
            let g = try old.add("beta", try old.other("beta"), "G", ext: "gg")
            try old.add("beta", g, "g1", url: "https://g1.example/", ext: "gg1")

            // "gamma": no external ids. "Plain" matches by path and title; p1 and one "same" are
            // already there, p2 and a third "same" are new; Y matches on the bar; a p1 on the
            // bar is another place, so another bookmark; a same-titled bookmark with another URL
            // is another bookmark.
            let c = try old.bar("gamma")
            try old.add("gamma", c, "Y", url: "https://y.example/")
            try old.add("gamma", c, "p1", url: "https://p1.example/")
            let cp = try old.add("gamma", c, "Plain")
            try old.add("gamma", cp, "p2", url: "https://p2.example/")
            try old.add("gamma", cp, "p1", url: "https://p1.example/")
            try old.add("gamma", cp, "same", url: "https://same.example/")
            try old.add("gamma", cp, "same", url: "https://same.example/")
            try old.add("gamma", cp, "same", url: "https://same.example/")
            try old.add("gamma", cp, "p1", url: "https://p1-moved.example/")
        }
        let db = try BrowserDatabase(fileURL: dbURL)
        let tree = try db.bookmarks.tree()
        XCTAssertEqual(outline(tree[0].children), [
            "X", "F/[a1,a2,b only]", "Y", "Plain/[p1,same,same,p2,same,p1]", "p1", "Z",
        ])
        XCTAssertEqual(outline(tree[1].children), ["G/[g1]"])
        XCTAssertEqual(tree[0].children[1].bookmark.title, "F", "the primary space's copy is kept")
        XCTAssertEqual(tree[0].children[3].children.last?.bookmark.url, "https://p1-moved.example/")
        try assertDense(db)
    }

    /// A Brave bookmark edited in one space keeps both versions; a folder renamed in a secondary
    /// space is still the same folder. The primary tree is kept as it is, even two items with one
    /// Brave id. An id-less copy and a Brave copy of one bookmark in another space match two.
    func testEditsAndDuplicatesSurvive() throws {
        try makeOldDatabase { old in
            let a = try old.bar("alpha")
            try old.add("alpha", a, "Mail", url: "https://old.example/", ext: "g1")
            try old.add("alpha", a, "Mail", url: "https://old.example/", ext: "g1")
            let f = try old.add("alpha", a, "Folder", ext: "gf")
            try old.add("alpha", f, "Foo", url: "https://foo.example/", ext: "gfoo")
            try old.add("alpha", f, "Foo", url: "https://foo.example/")
            try old.add("alpha", a, "Pad", url: "https://pad.example/")

            let b = try old.bar("beta")
            try old.add("beta", b, "Mail", url: "https://new.example/", ext: "g1")
            let bf = try old.add("beta", b, "Folder renamed", ext: "gf")
            try old.add("beta", bf, "Foo", url: "https://foo.example/")
            try old.add("beta", bf, "Foo", url: "https://foo.example/", ext: "gfoo")
            try old.add("beta", bf, "New", url: "https://n.example/")
        }
        let db = try BrowserDatabase(fileURL: dbURL)
        let bar = try db.bookmarks.tree()[0].children
        XCTAssertEqual(outline(bar), ["Mail", "Mail", "Folder/[Foo,Foo,New]", "Pad", "Mail"])
        XCTAssertEqual(bar.map { $0.bookmark.url ?? "" },
                       ["https://old.example/", "https://old.example/", "", "https://pad.example/", "https://new.example/"])
    }

    /// A merge that fails on a readable file leaves it where it was (it isn't taken for damaged
    /// and moved aside), with the backup next to it.
    func testFailedMergeLeavesTheFileInPlace() throws {
        try makeOldDatabase { old in try braveImport(old, space: "contoso") }
        // A visit pointing at no page: the migration's foreign key check fails.
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: "INSERT INTO history_visit (urlID, visitedAt) VALUES (999, 0)")
        }
        try queue.close()
        XCTAssertThrowsError(try BrowserDatabase(fileURL: dbURL)) { error in
            guard case .migrationFailed = error as? BrowserDataError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        let unreadable = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("unreadable") }
        XCTAssertEqual(unreadable, [])
        XCTAssertEqual(try backups().count, 1)
        let check = try DatabaseQueue(path: dbURL.path)
        let hasSpace = try check.read { try $0.columns(in: "bookmark").contains { $0.name == "space" } }
        try check.close()
        XCTAssertTrue(hasSpace, "rolled back")
    }

    func testTiesGoToTheFirstSpaceID() throws {
        try makeOldDatabase { old in
            try old.add("b-space", try old.bar("b-space"), "From B", url: "https://same.example/")
            try old.add("a-space", try old.bar("a-space"), "From A", url: "https://same.example/")
        }
        let db = try BrowserDatabase(fileURL: dbURL)
        XCTAssertEqual(try db.bookmarks.tree()[0].children.map(\.bookmark.title), ["From A", "From B"])
    }

    func testFreshDatabaseNeedsNoBackup() throws {
        let db = try BrowserDatabase(fileURL: dbURL)
        XCTAssertEqual(try backups(), [])
        XCTAssertEqual(try db.bookmarks.tree().map(\.children.count), [0, 0])
        XCTAssertEqual(try db.writer.read { try BrowserDatabase.migrator.appliedMigrations($0) },
                       ["v1", "v2-agent", "v3-global-bookmarks"])
        try db.bookmarks.add(parent: nil, title: "A", url: "https://a.example/")
        let reopened = try BrowserDatabase(fileURL: dbURL)
        XCTAssertEqual(try reopened.bookmarks.tree()[0].children.map(\.bookmark.title), ["A"])
        XCTAssertEqual(try backups(), [])
    }

    func testOldDatabaseWithoutBookmarksNeedsNoBackup() throws {
        try makeOldDatabase { _ in }
        let db = try BrowserDatabase(fileURL: dbURL)
        XCTAssertEqual(try backups(), [])
        XCTAssertEqual(try db.bookmarks.tree().map(\.children.count), [0, 0])
    }

    func testInMemoryDatabaseMigrates() throws {
        let db = try BrowserDatabase.inMemory()
        XCTAssertEqual(try db.bookmarks.tree().map(\.bookmark.root), [.bar, .other])
    }

    /// When the copy can't be made, the migration doesn't run and the file keeps its old schema.
    func testFailedBackupStopsTheMigration() throws {
        try makeOldDatabase { old in try braveImport(old, space: "contoso") }
        let pool = try DatabasePool(path: dbURL.path)
        let nowhere = dir.appendingPathComponent("missing", isDirectory: true).appendingPathComponent("browser.sqlite")
        XCTAssertThrowsError(try BrowserDatabase.backUpBeforeGlobalBookmarks(pool, fileURL: nowhere)) { error in
            guard case .backupFailed = error as? BrowserDataError else { return XCTFail("\(error)") }
        }
        let hasSpace = try pool.read { try $0.columns(in: "bookmark").contains { $0.name == "space" } }
        XCTAssertTrue(hasSpace)
        try pool.close()
    }
}
