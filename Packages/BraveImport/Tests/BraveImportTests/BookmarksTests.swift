import BraveImport
import XCTest

final class BookmarksTests: XCTestCase {
    private func fixture() throws -> BraveBookmarks {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "Bookmarks", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try BookmarksReader.read(contentsOf: url)
    }

    func testRootsInOrderWithBraveTitles() throws {
        let bookmarks = try fixture()
        XCTAssertEqual(bookmarks.roots.map(\.root), [.bookmarkBar, .other, .mobile])
        XCTAssertEqual(bookmarks.roots.map(\.folder.title), ["Bookmarks bar", "Other bookmarks", "Mobile bookmarks"])
        XCTAssertEqual(bookmarks.bookmarkCount, 6)
        XCTAssertEqual(bookmarks.folderCount, 4, "Work, Ünïcödé Földer, Level 3, Empty")
    }

    func testNestedFoldersUnicodeAndOrder() throws {
        let bar = try fixture().roots[0].folder
        XCTAssertEqual(bar.children.map(\.title), ["Example", "Work", "Empty"])

        let work = bar.children[1]
        XCTAssertTrue(work.isFolder)
        XCTAssertEqual(work.children.map(\.title), ["東京 – Tōkyō 🗼", "Ünïcödé Földer", "Bookmarklet"],
                       "the separator-typed node is skipped")
        XCTAssertEqual(work.children[0].url, "https://ja.wikipedia.org/wiki/%E6%9D%B1%E4%BA%AC")
        XCTAssertEqual(work.children[2].url, "javascript:alert('hi')", "bookmarklets are kept as stored")

        let unicodeFolder = work.children[1]
        XCTAssertEqual(unicodeFolder.children.map(\.title), ["Level 3", "שלום עולם"])
        XCTAssertEqual(unicodeFolder.children[1].url, "https://bücher.example/")
        let level3 = unicodeFolder.children[0]
        XCTAssertEqual(level3.children.first?.title, "Deep ✓")
        XCTAssertEqual(level3.children.first?.url, "https://deep.example/a?b=c#d")
        XCTAssertEqual(level3.children.first?.guid, "g-deep")

        XCTAssertTrue(bar.children[2].isFolder)
        XCTAssertEqual(bar.children[2].children, [])
    }

    func testDates() throws {
        let bookmarks = try fixture()
        let example = bookmarks.roots[0].folder.children[0]
        XCTAssertEqual(example.dateAdded, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(example.dateLastUsed, Date(timeIntervalSince1970: 1_710_000_000))
        XCTAssertNil(example.dateModified)

        let work = bookmarks.roots[0].folder.children[1]
        XCTAssertEqual(work.dateAdded, Date(timeIntervalSince1970: 1_700_000_050))
        XCTAssertEqual(work.dateModified, Date(timeIntervalSince1970: 1_700_000_400))
        XCTAssertNil(work.children[0].dateLastUsed, "\"0\" means never")
        XCTAssertNil(bookmarks.roots[1].folder.dateModified)

        let untitled = bookmarks.roots[1].folder.children[0]
        XCTAssertEqual(untitled.title, "")
        XCTAssertEqual(untitled.url, "https://untitled.example/")
    }

    func testUnknownRootsAreKeptAndJunkSkipped() throws {
        let json = """
            {"roots": {"bookmark_bar": {"type": "folder", "name": "Bar", "children": []},
                       "account_bookmark_bar": {"type": "folder", "name": "Account bar",
                          "children": [{"type": "url", "name": "A", "url": "https://a.example/"},
                                       {"type": "url", "name": "no url"}, 42, "junk"]},
                       "sync_transaction_version": "7"},
             "version": 1}
            """
        let bookmarks = try BookmarksReader.parse(Data(json.utf8))
        XCTAssertEqual(bookmarks.roots.map(\.root), [.bookmarkBar, .unknown("account_bookmark_bar")])
        XCTAssertEqual(bookmarks.roots[1].folder.children.map(\.title), ["A"])
        XCTAssertEqual(bookmarks.bookmarkCount, 1)
    }

    func testMalformedFiles() {
        XCTAssertThrowsError(try BookmarksReader.parse(Data("not json".utf8)))
        XCTAssertThrowsError(try BookmarksReader.parse(Data("{\"version\": 1}".utf8))) { error in
            XCTAssertEqual(error as? BookmarksError, .malformed("no roots object"))
        }
    }

    func testProfileWithoutBookmarksIsEmpty() throws {
        let dir = try makeTempDirectory("BookmarksTests")
        defer { try? FileManager.default.removeItem(at: dir) }
        let profile = BraveProfile(directoryName: "Default", displayName: "Default", url: dir)
        XCTAssertEqual(try BookmarksReader.read(profile: profile).roots.count, 0)
    }
}
