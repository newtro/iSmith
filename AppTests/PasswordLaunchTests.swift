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
        try PasswordStore(fileURL: url, keyStore: keys, mode: .app).add(origin: site(1), username: "a", password: "b")
        // An older copy of the app (rollback journal, before WAL) still quitting holds a write
        // lock, which in that mode keeps readers out too.
        _ = try sql("PRAGMA journal_mode = DELETE")
        let other = try sql("BEGIN EXCLUSIVE", keepOpen: true)
        var asked: [(String, Bool)] = []
        let opened = BrowserState.openPasswordStore(fileURL: url, keyStore: keys, ask: { asked.append(($0, $1)); return .continueWithout })
        XCTAssertNil(opened.store)
        XCTAssertEqual(asked.count, 1, "the user is told, with Try Again")
        XCTAssertEqual(asked.first?.1, false, "starting over isn't offered for a busy file")
        XCTAssertTrue(opened.problem?.contains("couldn't be read") == true, opened.problem ?? "")
        XCTAssertTrue(PasswordStore.setAsideCopies(of: url).isEmpty, "nothing was moved aside")
        sqlite3_exec(other, "COMMIT", nil, nil, nil)
        sqlite3_close(other)

        // "Try Again" once the lock is gone opens the same logins.
        var tries = 0
        let retried = BrowserState.openPasswordStore(fileURL: url, keyStore: keys, ask: { _, _ in tries += 1; return .tryAgain })
        XCTAssertEqual(tries, 0)
        XCTAssertEqual(try XCTUnwrap(retried.store).allLogins().count, 1)
    }

    /// Lists the folder's files with their bytes (the -shm, SQLite's shared-memory index that any
    /// reader updates, by name only).
    private func snapshot() throws -> [String: Data] {
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            files[name] = name.hasSuffix("-shm") ? Data() : try Data(contentsOf: dir.appendingPathComponent(name))
        }
        return files
    }

    func testAMissingKeyIsReportedAndNeverStartsOverOnItsOwn() throws {
        try PasswordStore(fileURL: url, keyStore: InMemoryKeyStore(), mode: .app).add(origin: site(1), username: "a", password: "b")
        let before = try snapshot()
        let keys = InMemoryKeyStore()
        var asked: [(String, Bool)] = []
        let opened = BrowserState.openPasswordStore(fileURL: url, keyStore: keys, ask: { asked.append(($0, $1)); return .continueWithout })
        XCTAssertNil(opened.store)
        XCTAssertEqual(asked.count, 1)
        XCTAssertEqual(asked.first?.1, true, "starting over is offered")
        XCTAssertTrue(asked.first?.0.contains("isn't in the login Keychain") == true, asked.first?.0 ?? "")
        XCTAssertTrue(opened.problem?.contains("Saved passwords are off") == true, opened.problem ?? "")
        XCTAssertNil(keys.key, "no key was created")
        XCTAssertEqual(try snapshot(), before, "nothing on disk changed")

        // "Try Again" keeps asking while the key is missing, and still changes nothing.
        var tries = 0
        let retried = BrowserState.openPasswordStore(fileURL: url, keyStore: keys, ask: { _, _ in
            tries += 1
            return tries < 3 ? .tryAgain : .continueWithout
        })
        XCTAssertNil(retried.store)
        XCTAssertEqual(tries, 3)
        XCTAssertNil(keys.key)
        XCTAssertEqual(try snapshot(), before)
    }

    func testStartingOverKeepsTheOldFileAndSaysWhere() throws {
        try PasswordStore(fileURL: url, keyStore: InMemoryKeyStore(), mode: .app).add(origin: site(1), username: "a", password: "b")
        let original = try Data(contentsOf: url)
        let keys = InMemoryKeyStore()
        var offered: [Bool] = []
        let opened = BrowserState.openPasswordStore(fileURL: url, keyStore: keys, ask: { _, canStartOver in
            offered.append(canStartOver)
            return .startOver
        })
        XCTAssertEqual(offered, [true])
        let store = try XCTUnwrap(opened.store)
        XCTAssertNil(opened.problem)
        XCTAssertEqual(store.openMode, .appStartOver)
        XCTAssertNotNil(keys.key, "a new key")
        let aside = try XCTUnwrap(store.movedAside)
        XCTAssertEqual(try Data(contentsOf: aside), original, "the old file is kept")
        XCTAssertTrue(try store.allLogins().isEmpty)

        var reported = Set<String>()
        let report = BrowserState.checkPasswordStore(store, reported: &reported)
        XCTAssertTrue(report.startedOver)
        let message = try XCTUnwrap(report.message)
        XCTAssertEqual(message.title, "A new passwords file was started")
        XCTAssertTrue(message.text.contains(aside.path), message.text)
    }

    func testTheLaunchCheckIsAppOnly() throws {
        let keys = InMemoryKeyStore()
        let earlier = try PasswordStore(fileURL: url, keyStore: keys, mode: .app)
        try earlier.add(origin: site(1), username: "u1", password: "p1")
        try earlier.close()
        let copy = dir.appendingPathComponent("passwords.unreadable-100.sqlite")
        try FileManager.default.moveItem(at: url, to: copy)
        let app = try PasswordStore(fileURL: url, keyStore: keys, mode: .app)
        let agent = try PasswordStore(fileURL: url, keyStore: keys, mode: .existingOnly)
        var reported = Set<String>()
        let report = BrowserState.checkPasswordStore(agent, reported: &reported)
        XCTAssertTrue(report.restored.isEmpty, "another process never restores")
        XCTAssertTrue(try app.allLogins().isEmpty)
        XCTAssertThrowsError(try agent.recover(from: copy))
        // The app does.
        XCTAssertEqual(BrowserState.checkPasswordStore(app, reported: &reported).restored.map(\.count), [1])
    }

    func testLaunchCheckRestoresCopiesSetAsideAndReportsUnreadableLogins() throws {
        let keys = InMemoryKeyStore()
        // An earlier store that was moved aside, and one sealed with a key that's gone.
        let earlier = try PasswordStore(fileURL: url, keyStore: keys, mode: .app)
        for i in 0..<3 { try earlier.add(origin: site(i), username: "u\(i)", password: "p\(i)") }
        try earlier.close()
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("passwords.unreadable-100.sqlite"))
        try PasswordStore(fileURL: url, keyStore: InMemoryKeyStore(), mode: .app).add(origin: site(9), username: "x", password: "y")
        try FileManager.default.moveItem(at: url, to: dir.appendingPathComponent("passwords.unreadable-200.sqlite"))

        let store = try PasswordStore(fileURL: url, keyStore: keys, mode: .app)
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
        let reopened = try PasswordStore(fileURL: url, keyStore: keys, mode: .app)
        let damaged = BrowserState.checkPasswordStore(reopened, reported: &reported)
        XCTAssertEqual(damaged.health, PasswordStore.Health(rows: 4, unreadable: 1))
        XCTAssertTrue(damaged.message?.text.contains("1 of 4 saved logins can't be decrypted") == true, damaged.message?.text ?? "")
    }
}
