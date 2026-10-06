import Passwords
import SignInSync
import SQLite3
import XCTest
@testable import iSmith

/// The passwords store at launch: a store that can't be opened is reported (never a silently
/// empty list), earlier copies set aside are added back, and logins that don't decrypt are
/// counted and reported.
@MainActor
final class PasswordLaunchTests: XCTestCase {
    private var dir: URL!
    private var url: URL { dir.appendingPathComponent("passwords.sqlite") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("PasswordLaunch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func site(_ i: Int) -> Origin { Origin(string: "https://site\(i).example")! }

    /// Runs SQL on the file through a connection of its own (another process, as far as the
    /// store can tell).
    private func sql(_ statement: String, keepOpen: Bool = false) throws -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw NSError(domain: "sqlite", code: 1) }
        guard sqlite3_exec(db, statement, nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw NSError(domain: "sqlite", code: 2)
        }
        if keepOpen { return db }
        sqlite3_close(db)
        return nil
    }

    func testAStoreThatCantBeOpenedIsReportedAndLeftAlone() throws {
        let keys = InMemoryKeyStore()
        try PasswordStore(fileURL: url, keyStore: keys).add(origin: site(1), username: "a", password: "b")
        // Another process holds a write lock (an older copy of the app still quitting, say).
        let other = try sql("BEGIN EXCLUSIVE", keepOpen: true)
        var asked: [String] = []
        let opened = BrowserState.openPasswordStore(fileURL: url, keyStore: keys, ask: { asked.append($0); return false })
        XCTAssertNil(opened.store)
        XCTAssertEqual(asked.count, 1, "the user is told, with Try Again")
        XCTAssertTrue(opened.problem?.contains("couldn't be read") == true, opened.problem ?? "")
        XCTAssertTrue(PasswordStore.setAsideCopies(of: url).isEmpty, "nothing was moved aside")
        sqlite3_exec(other, "COMMIT", nil, nil, nil)
        sqlite3_close(other)

        // "Try Again" once the lock is gone opens the same logins.
        var tries = 0
        let retried = BrowserState.openPasswordStore(fileURL: url, keyStore: keys, ask: { _ in tries += 1; return true })
        XCTAssertEqual(tries, 0)
        XCTAssertEqual(try XCTUnwrap(retried.store).allLogins().count, 1)
    }

    func testLaunchCheckRestoresCopiesSetAsideAndReportsUnreadableLogins() throws {
        let keys = InMemoryKeyStore()
        // An earlier store that was moved aside, and one sealed with a key that's gone.
        let earlier = try PasswordStore(fileURL: url, keyStore: keys)
        for i in 0..<3 { try earlier.add(origin: site(i), username: "u\(i)", password: "p\(i)") }
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("passwords.unreadable-100.sqlite"))
        try PasswordStore(fileURL: url, keyStore: InMemoryKeyStore()).add(origin: site(9), username: "x", password: "y")
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("passwords.unreadable-200.sqlite"))

        let store = try PasswordStore(fileURL: url, keyStore: keys)
        try store.add(origin: site(5), username: "u5", password: "p5")
        var reported = Set<String>()
        let report = BrowserState.checkPasswordStore(store, reported: &reported)
        XCTAssertEqual(report.restored.map(\.count), [3])
        XCTAssertNotNil(report.restored.first?.backup)
        XCTAssertEqual(report.unopenable.map(\.lastPathComponent), ["passwords.unreadable-200.sqlite"])
        XCTAssertEqual(report.health, PasswordStore.Health(rows: 4, unreadable: 0))
        XCTAssertEqual(try store.allLogins().count, 4)
        let message = try XCTUnwrap(report.message)
        XCTAssertTrue(message.text.contains("3 saved logins from an earlier copy"), message.text)
        XCTAssertTrue(message.text.contains("passwords.unreadable-200.sqlite"), message.text)

        // The next launch has nothing new to say.
        XCTAssertNil(BrowserState.checkPasswordStore(store, reported: &reported).message)

        // A row that no longer decrypts is counted and said, not dropped from view silently.
        _ = try sql("UPDATE login SET origin = 'https://elsewhere.example' WHERE origin = 'https://site5.example'")
        let reopened = try PasswordStore(fileURL: url, keyStore: keys)
        let damaged = BrowserState.checkPasswordStore(reopened, reported: &reported)
        XCTAssertEqual(damaged.health, PasswordStore.Health(rows: 4, unreadable: 1))
        XCTAssertTrue(damaged.message?.text.contains("1 of 4 saved logins can't be decrypted") == true, damaged.message?.text ?? "")
    }
}
