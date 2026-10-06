@testable import BrowserData
import GRDB
import XCTest

/// The file on disk: owner-only permissions, reopening, and an unreadable file moved aside.
final class BrowserDatabaseTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL { BrowserDatabase.defaultFileURL(dataDirectory: dir) }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BrowserDataTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("iSmith", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir.deletingLastPathComponent())
    }

    private func permissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testFileIsOwnerOnlyAndNamedBrowserSqlite() throws {
        let db = try BrowserDatabase(fileURL: dbURL)
        try db.history.recordVisit(space: "s", url: URL(string: "https://a.com")!, title: "A")
        XCTAssertEqual(dbURL.lastPathComponent, "browser.sqlite")
        XCTAssertEqual(try permissions(dir), 0o700)
        XCTAssertEqual(try permissions(dbURL), 0o600)
        for side in SecureFile.sideFiles(of: dbURL) where FileManager.default.fileExists(atPath: side.path) {
            XCTAssertEqual(try permissions(side), 0o600, side.lastPathComponent)
        }
        XCTAssertNil(db.movedAside)
    }

    func testReopeningKeepsDataAndSchemaVersion() throws {
        do {
            let db = try BrowserDatabase(fileURL: dbURL)
            try db.history.recordVisit(space: "s", url: URL(string: "https://a.com")!, title: "A")
            try db.bookmarks.add(parent: nil, title: "B", url: "https://b.com")
            try db.sites.setZoom(1.1, host: "a.com")
        }
        // Loosened permissions are tightened again on open.
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: dbURL.path)
        let db = try BrowserDatabase(fileURL: dbURL)
        XCTAssertNil(db.movedAside)
        XCTAssertEqual(try permissions(dbURL), 0o600)
        XCTAssertEqual(try db.history.visits(space: "s", matching: "", limit: 10).map(\.title), ["A"])
        XCTAssertEqual(try db.bookmarks.search("b.com", limit: 10).count, 1)
        XCTAssertEqual(try db.sites.zoom(host: "a.com"), 1.1)
        let applied = try db.writer.read { try BrowserDatabase.migrator.appliedMigrations($0) }
        XCTAssertEqual(applied, ["v1", "v2-agent", "v3-global-bookmarks", "v4-site-app-links"])
        XCTAssertEqual(try db.writer.read { try BrowserDatabase.migrator.hasCompletedMigrations($0) }, true)
    }

    func testCorruptFileIsMovedAsideAndAFreshDatabaseOpens() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0x5A, count: 8192).write(to: dbURL)
        try Data("junk".utf8).write(to: URL(fileURLWithPath: dbURL.path + "-wal"))

        let db = try BrowserDatabase(fileURL: dbURL)
        let moved = try XCTUnwrap(db.movedAside)
        XCTAssertTrue(moved.lastPathComponent.hasPrefix("browser.unreadable-"), moved.lastPathComponent)
        XCTAssertEqual(moved.pathExtension, "sqlite")
        XCTAssertEqual(try Data(contentsOf: moved), Data(repeating: 0x5A, count: 8192), "kept for recovery")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path + "-wal"), "side files go with it")

        try db.history.recordVisit(space: "s", url: URL(string: "https://a.com")!, title: "A")
        XCTAssertEqual(try db.history.visits(space: nil, matching: "", limit: 10).count, 1)
        XCTAssertEqual(try permissions(dbURL), 0o600)
    }

    func testConcurrentReadsAndWrites() throws {
        let db = try BrowserDatabase(fileURL: dbURL)
        DispatchQueue.concurrentPerform(iterations: 8) { i in
            for j in 0..<25 {
                if i % 2 == 0 {
                    try? db.history.recordVisit(space: "s", url: URL(string: "https://site\(i)-\(j).com/")!, title: "T",
                                                at: Date(timeIntervalSince1970: Double(1_800_000_000 + i * 100 + j * 2)))
                } else {
                    _ = try? db.history.suggestions(for: "site", space: "s", limit: 8)
                }
            }
        }
        XCTAssertEqual(try db.history.visits(space: "s", matching: "", limit: 1000).count, 100)
    }
}
