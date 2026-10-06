import BraveImport
import BrowserData
import Passwords
import SQLite3
import XCTest
@testable import iSmith

/// P5 wiring: a fixture Brave profile (bookmarks JSON and a Chromium `Login Data` with encrypted
/// passwords) imported through the import screen's model into a space's bookmarks and the
/// password store, with counts, a second import adding nothing, the Keychain notice coming before
/// any Keychain read, and macOS's "permission denied" shown as such. Never the real Brave or the
/// real "Brave Safe Storage" item.
@MainActor
final class BraveImportWiringTests: XCTestCase {
    private var wired: WiredBrowser!
    private var root: URL!
    private static let safeStoragePassword = "fixture-safe-storage"

    /// A fixed "Brave Safe Storage" password that counts how often it's asked for.
    final class FixtureSafeStorage: SafeStoragePasswordSource, @unchecked Sendable {
        private let lock = NSLock()
        private var _calls = 0
        var calls: Int { lock.withLock { _calls } }
        func safeStoragePassword() throws -> Data {
            lock.withLock { _calls += 1 }
            return Data(BraveImportWiringTests.safeStoragePassword.utf8)
        }
    }

    override func setUp() async throws {
        wired = try WiredBrowser()
        root = wired.dir.appendingPathComponent("Brave-Browser", isDirectory: true)
        let profile = root.appendingPathComponent("Default", isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        try Data(#"{"profile":{"info_cache":{"Default":{"name":"Scott"}},"profiles_order":["Default"]}}"#.utf8)
            .write(to: root.appendingPathComponent("Local State"))
        try Data(Self.bookmarks.utf8).write(to: profile.appendingPathComponent("Bookmarks"))
        try makeLoginData(profile.appendingPathComponent("Login Data"))
    }

    override func tearDown() async throws {
        if let root { chmod(root.path, 0o755) }
        await wired?.tearDown()
    }

    private static let bookmarks = """
        {"roots":{
          "bookmark_bar":{"type":"folder","name":"Bookmarks bar","guid":"bar-root","children":[
            {"type":"url","name":"GitHub","url":"https://github.com/","guid":"bm-github","date_added":"13300000000000000"},
            {"type":"folder","name":"Work","guid":"folder-work","children":[
              {"type":"url","name":"DevOps","url":"https://dev.azure.com/contoso-dev","guid":"bm-devops"}]}]},
          "other":{"type":"folder","name":"Other bookmarks","guid":"other-root","children":[
            {"type":"url","name":"Etsy","url":"https://www.etsy.com/","guid":"bm-etsy"}]},
          "synced":{"type":"folder","name":"Mobile bookmarks","guid":"mobile-root","children":[
            {"type":"url","name":"News","url":"https://news.example/","guid":"bm-news"}]}
        },"version":1}
        """

    /// Chromium's `logins` table (the columns BraveImport reads), with Brave's encryption.
    private func makeLoginData(_ url: URL) throws {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        defer { sqlite3_close(db) }
        let schema = """
            CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR,
              username_value VARCHAR, password_element VARCHAR, password_value BLOB, signon_realm VARCHAR NOT NULL,
              date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL, scheme INTEGER NOT NULL,
              times_used_in_html_form INTEGER, id INTEGER PRIMARY KEY AUTOINCREMENT,
              date_last_used INTEGER NOT NULL DEFAULT 0, date_password_modified INTEGER NOT NULL DEFAULT 0);
            """
        XCTAssertEqual(sqlite3_exec(db, schema, nil, nil, nil), SQLITE_OK)
        let cipher = try ChromiumPasswordCipher(safeStoragePassword: Data(Self.safeStoragePassword.utf8))
        // 2025-06-01 in Chromium time (µs since 1601).
        let modified: Int64 = (1_748_736_000 + 11_644_473_600) * 1_000_000
        let rows: [(String, String, String, Data, Bool)] = [
            ("https://login.example.com/signin", "https://login.example.com/", "scott", try cipher.encrypt("Pass-One-1"), false),
            ("https://shop.example/login", "https://shop.example/", "shopper", try cipher.encrypt("Pass-Two-2-new"), false),
            ("https://never.example/", "https://never.example/", "", Data(), true),
            ("android://hash@com.example.app/", "android://hash@com.example.app/", "app-user", try cipher.encrypt("App-Pass"), false),
        ]
        for (origin, realm, user, password, never) in rows {
            var stmt: OpaquePointer?
            let sql = """
                INSERT INTO logins (origin_url, action_url, username_element, username_value, password_element, password_value,
                  signon_realm, date_created, blacklisted_by_user, scheme, times_used_in_html_form, date_last_used, date_password_modified)
                VALUES (?, '', 'u', ?, 'p', ?, ?, ?, ?, 0, 3, ?, ?)
                """
            XCTAssertEqual(sqlite3_prepare_v2(db, sql, -1, &stmt, nil), SQLITE_OK)
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(stmt, 1, origin, -1, transient)
            sqlite3_bind_text(stmt, 2, user, -1, transient)
            _ = password.withUnsafeBytes { sqlite3_bind_blob(stmt, 3, $0.baseAddress, Int32(password.count), transient) }
            sqlite3_bind_text(stmt, 4, realm, -1, transient)
            sqlite3_bind_int64(stmt, 5, modified)
            sqlite3_bind_int(stmt, 6, never ? 1 : 0)
            sqlite3_bind_int64(stmt, 7, modified)
            sqlite3_bind_int64(stmt, 8, modified)
            XCTAssertEqual(sqlite3_step(stmt), SQLITE_DONE)
            sqlite3_finalize(stmt)
        }
    }

    private func titles(_ nodes: [BookmarkTree]) -> [String] {
        nodes.map { $0.bookmark.isFolder ? "\($0.bookmark.title)/[\(titles($0.children).joined(separator: ","))]" : $0.bookmark.title }
    }

    func testImportMapsBookmarksIntoASpaceAndPasswordsIntoTheStore() async throws {
        let browser = wired.browser
        let store = try XCTUnwrap(browser.passwords?.store)
        // Already in iSmith: shop.example with an older password (Brave's newer one wins) and
        // login.example.com with the same password Brave has.
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        try store.add(origin: Origin(string: "https://shop.example")!, username: "shopper", password: "Pass-Two-2-old", date: old)
        try store.add(origin: Origin(string: "https://kept.example")!, username: "k", password: "K-1", date: old)

        let safeStorage = FixtureSafeStorage()
        let model = ImportFromBraveModel(browser: browser, firstRun: true, root: root)
        model.safeStorage = { safeStorage }
        await model.load()
        XCTAssertEqual(model.phase, .choose)
        XCTAssertEqual(model.profiles.map(\.profile.displayName), ["Scott"])
        XCTAssertEqual(model.profiles.first?.bookmarks, 4)
        XCTAssertTrue(model.importBookmarks)
        XCTAssertTrue(model.importPasswords)

        // "Import" with passwords first explains macOS's Keychain prompt; nothing is read yet.
        model.start()
        XCTAssertEqual(model.phase, .keychainNotice)
        XCTAssertEqual(safeStorage.calls, 0, "the Keychain isn't touched before the user continues")
        await model.run(passwords: true)
        XCTAssertEqual(model.phase, .done)
        XCTAssertEqual(safeStorage.calls, 1, "asked once for the whole import")

        // Bookmarks: the bar into the space's bar, the rest into Other Bookmarks, folders kept.
        let bookmarks = try XCTUnwrap(model.bookmarkSummary)
        XCTAssertEqual(bookmarks, BookmarkImportSummary(bookmarksInBrave: 4, foldersInBrave: 1,
                                                        bookmarksAdded: 4, foldersAdded: 2, alreadyThere: 0))
        let tree = try XCTUnwrap(browser.data?.bookmarks.tree())
        let bar = try XCTUnwrap(tree.first { $0.bookmark.root == .bar })
        let other = try XCTUnwrap(tree.first { $0.bookmark.root == .other })
        XCTAssertEqual(titles(bar.children), ["GitHub", "Work/[DevOps]"])
        XCTAssertEqual(titles(other.children), ["Etsy", "Mobile Bookmarks/[News]"])
        XCTAssertEqual(bar.children.first?.bookmark.url, "https://github.com/")
        XCTAssertEqual(bar.children.first?.bookmark.externalID, "bm-github")

        // Passwords: website logins in the store; never-save and app logins skipped and counted.
        let passwords = try XCTUnwrap(model.passwordSummary)
        XCTAssertEqual(passwords.inBrave, 3)
        XCTAssertEqual(passwords.added, 1)
        XCTAssertEqual(passwords.updated, 1)
        XCTAssertEqual(passwords.imported, 2)
        XCTAssertEqual(passwords.skippedNeverSave, 1)
        XCTAssertEqual(passwords.skippedNotWebsite, 1)
        XCTAssertEqual(passwords.failed, 0)
        let logins = try store.allLogins()
        XCTAssertEqual(Set(logins.map { "\($0.origin.serialized)|\($0.username)|\($0.password)" }), [
            "https://login.example.com|scott|Pass-One-1",
            "https://shop.example|shopper|Pass-Two-2-new",
            "https://kept.example|k|K-1",
        ])
        XCTAssertNotNil(logins.first { $0.username == "scott" }?.lastUsed, "Brave's last use carries over")

        // A second import adds nothing.
        await model.run(passwords: true)
        XCTAssertEqual(model.bookmarkSummary?.bookmarksAdded, 0)
        XCTAssertEqual(model.bookmarkSummary?.alreadyThere, 4)
        XCTAssertEqual(model.passwordSummary?.unchanged, 2)
        XCTAssertEqual(model.passwordSummary?.imported, 0)
        XCTAssertEqual(try store.allLogins().count, 3)
        let again = try XCTUnwrap(browser.data?.bookmarks.tree())
        XCTAssertEqual(titles(try XCTUnwrap(again.first { $0.bookmark.root == .bar }).children), ["GitHub", "Work/[DevOps]"])
    }

    /// Only bookmarks: no Keychain notice and no Keychain read.
    func testBookmarksOnlyNeverTouchesTheKeychain() async throws {
        let safeStorage = FixtureSafeStorage()
        let model = ImportFromBraveModel(browser: wired.browser, firstRun: false, root: root)
        model.safeStorage = { safeStorage }
        await model.load()
        model.importPasswords = false
        model.start()
        let done = await eventually { model.phase == .done }
        XCTAssertTrue(done)
        XCTAssertEqual(safeStorage.calls, 0)
        XCTAssertNil(model.passwordSummary)
        XCTAssertEqual(model.bookmarkSummary?.bookmarksAdded, 4)
    }

    /// Bookmarks are shared by every space, so there's no space to pick: an import goes into the
    /// one set, and importing again adds only what isn't there (by Brave's id), even if the user
    /// moved an imported bookmark to another folder.
    func testReimportAddsOnlyMissingBookmarks() async throws {
        let store = try XCTUnwrap(wired.browser.data?.bookmarks)
        let model = ImportFromBraveModel(browser: wired.browser, firstRun: false, root: root)
        await model.load()
        model.importPasswords = false
        await model.run(passwords: false)
        XCTAssertEqual(model.bookmarkSummary?.bookmarksAdded, 4)

        let bar = try XCTUnwrap(store.tree().first { $0.bookmark.root == .bar })
        let github = try XCTUnwrap(bar.children.first { $0.bookmark.title == "GitHub" })
        try store.move(github.bookmark.id, to: store.root(.other).id, at: 0)
        let work = try XCTUnwrap(bar.children.first { $0.bookmark.title == "Work" })
        try store.delete(XCTUnwrap(work.children.first).bookmark.id)

        await model.run(passwords: false)
        XCTAssertEqual(model.bookmarkSummary?.bookmarksAdded, 1, "only the deleted DevOps comes back")
        XCTAssertEqual(model.bookmarkSummary?.foldersAdded, 0)
        let tree = try store.tree()
        XCTAssertEqual(titles(try XCTUnwrap(tree.first { $0.bookmark.root == .bar }).children), ["Work/[DevOps]"])
        XCTAssertEqual(titles(try XCTUnwrap(tree.first { $0.bookmark.root == .other }).children),
                       ["GitHub", "Etsy", "Mobile Bookmarks/[News]"])
    }

    /// A wrong Safe Storage key (another install's) is explained, and nothing is saved.
    func testWrongKeyIsExplained() async throws {
        final class WrongKey: SafeStoragePasswordSource {
            func safeStoragePassword() throws -> Data { Data("not-the-key".utf8) }
        }
        let model = ImportFromBraveModel(browser: wired.browser, firstRun: false, root: root)
        model.safeStorage = { WrongKey() }
        await model.load()
        model.importBookmarks = false
        await model.run(passwords: true)
        XCTAssertEqual(model.phase, .done)
        XCTAssertNil(model.passwordSummary)
        XCTAssertEqual(model.passwordProblem, ImportFromBraveModel.explain(PasswordImportError.wrongKey))
        XCTAssertEqual(try wired.browser.passwords?.store.allLogins().count, 0)
    }

    /// macOS refusing to let iSmith read Brave's folder shows the permission screen, not "no
    /// Brave", and Try Again works once access is given.
    func testPermissionDeniedShowsThePermissionScreen() async throws {
        chmod(root.path, 0o000)
        let model = ImportFromBraveModel(browser: wired.browser, firstRun: false, root: root)
        await model.load()
        XCTAssertEqual(model.phase, .permissionDenied)
        chmod(root.path, 0o755)
        await model.load()
        XCTAssertEqual(model.phase, .choose)
        XCTAssertEqual(ImportFromBraveModel.fullDiskAccessURL.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
    }

    func testNoBrave() async {
        let model = ImportFromBraveModel(browser: wired.browser, firstRun: true, root: wired.dir.appendingPathComponent("missing"))
        await model.load()
        XCTAssertEqual(model.phase, .noBrave)
    }

    func testOriginsOfBraveLogins() {
        func login(_ origin: String, _ realm: String) -> ImportedLogin {
            ImportedLogin(origin: origin, signonRealm: realm, actionURL: nil, username: "u", password: "p", scheme: .html,
                          dateCreated: nil, dateLastUsed: nil, datePasswordModified: nil, timesUsed: 0, stores: [.profile])
        }
        XCTAssertEqual(BraveImporter.origin(of: login("https://a.example/login", "https://a.example/")), Origin(string: "https://a.example"))
        XCTAssertEqual(BraveImporter.origin(of: login("http://intranet:8080/", "http://intranet:8080/Realm Name")),
                       Origin(string: "http://intranet:8080"), "HTTP auth realms")
        XCTAssertNil(BraveImporter.origin(of: login("android://x@com.app/", "android://x@com.app/")))
    }
}
