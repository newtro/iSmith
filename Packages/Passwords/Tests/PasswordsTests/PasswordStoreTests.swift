import CryptoKit
import GRDB
@testable import Passwords
import SignInSync
import os
import XCTest

/// The encrypted store: crypto, files on disk, CRUD, matching, proposals, never-save, and what
/// happens with a missing, wrong or unreadable key.
final class PasswordStoreTests: XCTestCase {
    private var dir: URL!
    private var dbURL: URL { dir.appendingPathComponent("passwords.sqlite") }
    private let example = Origin(string: "https://example.com")!
    private let www = Origin(string: "https://www.example.com")!
    private let other = Origin(string: "https://other.org")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PasswordStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        PasswordStore.testHook = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// Every file in the folder, by name, with its bytes (the -shm index by name only).
    private func snapshot() throws -> [String: Data] {
        guard FileManager.default.fileExists(atPath: dir.path) else { return [:] }
        var files: [String: Data] = [:]
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir), isDir.boolValue { continue }
            // The -shm is SQLite's shared-memory index, not data: any connection that reads the
            // file updates it (read marks), so only its presence is compared.
            files[name] = name.hasSuffix("-shm") ? Data() : try Data(contentsOf: dir.appendingPathComponent(name))
        }
        return files
    }

    /// Turns a closed store's file back into the rollback-journal format it had before WAL.
    private func makeRollbackJournal(_ url: URL) throws {
        let queue = try DatabaseQueue(path: url.path)
        try queue.writeWithoutTransaction { db in
            XCTAssertEqual(try String.fetchOne(db, sql: "PRAGMA journal_mode = DELETE"), "delete")
        }
        try queue.close()
    }

    /// Moves a closed database with its side files, as `moveAside` does.
    private func moveDatabase(at from: URL, to: URL) throws {
        try FileManager.default.moveItem(at: from, to: to)
        for suffix in ["-journal", "-wal", "-shm"] where FileManager.default.fileExists(atPath: from.path + suffix) {
            try FileManager.default.moveItem(atPath: from.path + suffix, toPath: to.path + suffix)
        }
    }

    private func permissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    // MARK: Crypto

    func testFieldCryptoRoundTripAndBinding() throws {
        let key = SymmetricKey(size: .bits256)
        let id = UUID()
        let sealed = try LoginCrypto.seal("hunter2-secret", id: id, origin: example, field: .password, key: key)
        XCTAssertFalse(String(decoding: sealed, as: UTF8.self).contains("hunter2"))
        XCTAssertEqual(try LoginCrypto.open(sealed, id: id, origin: example, field: .password, key: key), "hunter2-secret")
        let again = try LoginCrypto.seal("hunter2-secret", id: id, origin: example, field: .password, key: key)
        XCTAssertNotEqual(sealed, again, "a fresh nonce every time")

        XCTAssertThrowsError(try LoginCrypto.open(sealed, id: id, origin: example, field: .password, key: SymmetricKey(size: .bits256)), "wrong key")
        XCTAssertThrowsError(try LoginCrypto.open(sealed, id: UUID(), origin: example, field: .password, key: key), "moved to another row")
        XCTAssertThrowsError(try LoginCrypto.open(sealed, id: id, origin: other, field: .password, key: key), "row's origin changed")
        XCTAssertThrowsError(try LoginCrypto.open(sealed, id: id, origin: example, field: .username, key: key), "moved to another field")
        var flipped = sealed
        flipped[flipped.count - 1] ^= 0x01
        XCTAssertThrowsError(try LoginCrypto.open(flipped, id: id, origin: example, field: .password, key: key), "tampered tag")
    }

    func testSecretsAreNotOnDiskOrInDescriptions() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertNotNil(keys.key, "a first run creates a key")
        let login = try store.add(origin: example, username: "scott@example.com", password: "Correct-Horse-Battery-77")

        // While open, the new rows are in the WAL; after closing, in the main file.
        let wal = URL(fileURLWithPath: dbURL.path + "-wal"), shm = URL(fileURLWithPath: dbURL.path + "-shm")
        let live = try Data(contentsOf: dbURL) + Data(contentsOf: wal)
        XCTAssertEqual(try permissions(wal), 0o600, "the WAL is owner-only")
        XCTAssertEqual(try permissions(shm), 0o600, "the shared-memory index is owner-only")
        try store.close()
        let raw = try Data(contentsOf: dbURL)
        for secret in ["scott@example.com", "Correct-Horse-Battery-77", "Correct-Horse"] {
            XCTAssertNil(live.range(of: Data(secret.utf8)), "\(secret) is not in the file or its WAL in the clear")
            XCTAssertNil(raw.range(of: Data(secret.utf8)), "\(secret) is not in the file in the clear")
        }
        XCTAssertNotNil(live.range(of: Data("https://example.com".utf8)), "origins are in the clear, for matching")
        XCTAssertNotNil(raw.range(of: Data("https://example.com".utf8)), "and checkpointed into the file on close")
        XCTAssertEqual(try permissions(dbURL), 0o600, "database is owner-only")
        XCTAssertEqual(try permissions(dir), 0o700, "folder is owner-only")

        for text in [String(describing: login), String(reflecting: login), "\(login)", dumped(login), String(describing: login.summary)] {
            XCTAssertFalse(text.contains("Correct-Horse"), "password redacted in \(text)")
            XCTAssertFalse(text.contains("scott@"), "username redacted in \(text)")
        }
    }

    private func dumped<T>(_ value: T) -> String {
        var out = ""
        dump(value, to: &out)
        return out
    }

    // MARK: CRUD

    func testCreateReadUpdateDelete() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try store.add(origin: example, username: "alice", password: "pw-a-1", date: t0)
        let b = try store.add(origin: example, username: "bob", password: "pw-b-1", date: t0)
        let c = try store.add(origin: other, username: "alice", password: "pw-c-1", date: t0)
        XCTAssertThrowsError(try store.add(origin: example, username: "alice", password: "x")) {
            XCTAssertEqual($0 as? PasswordStoreError, .duplicate)
        }

        // Reopened, as on the next launch.
        let reopened = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertNil(reopened.movedAside)
        XCTAssertEqual(try reopened.allLogins().map(\.id), [a.id, b.id, c.id], "by site, then username")
        XCTAssertEqual(try reopened.login(id: a.id)?.password, "pw-a-1")

        // Changing the password moves `updated`; changing only the username doesn't.
        var edited = try XCTUnwrap(reopened.login(id: a.id))
        edited.password = "pw-a-2"
        let t1 = t0.addingTimeInterval(60)
        let saved = try reopened.update(edited, date: t1)
        XCTAssertEqual(saved.updated, t1)
        XCTAssertEqual(try reopened.login(id: a.id)?.password, "pw-a-2")
        edited = saved
        edited.username = "alice2"
        XCTAssertEqual(try reopened.update(edited, date: t1.addingTimeInterval(60)).updated, t1)
        edited.username = "bob"
        XCTAssertThrowsError(try reopened.update(edited)) { XCTAssertEqual($0 as? PasswordStoreError, .duplicate) }

        // Moving a login to another origin re-encrypts it under that origin.
        var moved = try XCTUnwrap(reopened.login(id: c.id))
        moved.origin = www
        try reopened.update(moved)
        XCTAssertEqual(try reopened.login(id: c.id)?.origin, www)
        XCTAssertEqual(try reopened.login(id: c.id)?.password, "pw-c-1")

        try reopened.delete(id: b.id)
        XCTAssertNil(try reopened.login(id: b.id))
        XCTAssertEqual(try reopened.allLogins().count, 2)
        XCTAssertEqual(try reopened.unreadableCount(), 0)
    }

    func testSearchMatchesHostsAndUsernamesNotPasswords() throws {
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app)
        try store.add(origin: example, username: "Scott.Smith", password: "findme-not")
        try store.add(origin: other, username: "someone", password: "x-123")
        XCTAssertEqual(try store.search("EXAMPLE").count, 1)
        XCTAssertEqual(try store.search("smith").count, 1)
        XCTAssertEqual(try store.search("findme").count, 0, "passwords are never searched")
        XCTAssertEqual(try store.search("  ").count, 2)
    }

    func testLoginsForOriginAndLastUsed() throws {
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app)
        let exact = try store.add(origin: example, username: "exact", password: "1")
        let older = try store.add(origin: www, username: "sibling-old", password: "2")
        let newer = try store.add(origin: www, username: "sibling-new", password: "3")
        try store.add(origin: other, username: "unrelated", password: "4")
        try store.add(origin: Origin(string: "http://example.com")!, username: "insecure", password: "5")

        try store.markUsed(id: older.id, date: Date(timeIntervalSince1970: 1000))
        try store.markUsed(id: newer.id, date: Date(timeIntervalSince1970: 2000))
        let matches = try store.logins(for: example)
        XCTAssertEqual(matches.map(\.login.id), [exact.id, newer.id, older.id], "exact first, then most recently used")
        XCTAssertEqual(matches.map(\.kind), [.exact, .sameSite, .sameSite])
        XCTAssertEqual(try store.login(id: newer.id)?.timesUsed, 1)
        XCTAssertEqual(try store.login(id: newer.id)?.lastUsed, Date(timeIntervalSince1970: 2000))
        XCTAssertTrue(try store.logins(for: Origin(string: "https://example.net")!).isEmpty)
    }

    func testProposalsAndNeverSave() throws {
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app)
        XCTAssertEqual(try store.proposal(for: example, username: "alice", password: "one"), .save)
        let a = try store.save(origin: example, username: "alice", password: "one")
        XCTAssertEqual(try store.proposal(for: example, username: "alice", password: "one"), .unchanged(existing: a.id))
        XCTAssertEqual(try store.proposal(for: example, username: "alice", password: "two"), .update(existing: a.id))
        XCTAssertEqual(try store.proposal(for: example, username: "bob", password: "one"), .save)
        // Signed in on a sibling host with the sibling's login: nothing new to save.
        XCTAssertEqual(try store.proposal(for: www, username: "alice", password: "one"), .unchanged(existing: a.id))
        // Another password on the sibling host: a login of its own, the original untouched.
        XCTAssertEqual(try store.proposal(for: www, username: "alice", password: "two"), .save)

        let updated = try store.save(origin: example, username: "alice", password: "two")
        XCTAssertEqual(updated.id, a.id, "saving an existing username updates it")
        XCTAssertEqual(try store.login(id: a.id)?.password, "two")

        try store.setNeverSave(other)
        XCTAssertEqual(try store.proposal(for: other, username: "x", password: "y"), .neverSave)
        XCTAssertTrue(try store.isNeverSave(other))
        XCTAssertFalse(try store.isNeverSave(Origin(string: "https://www.other.org")!), "never-save is per exact origin")
        XCTAssertEqual(try store.neverSaveOrigins(), [other])
        try store.removeNeverSave(other)
        XCTAssertEqual(try store.proposal(for: other, username: "x", password: "y"), .save)
    }

    // MARK: Keys

    func testKeychainUnavailableTouchesNothing() throws {
        let keys = InMemoryKeyStore()
        try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app).add(origin: example, username: "a", password: "b")
        let before = try Data(contentsOf: dbURL)
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: FailingKeyStore(), mode: .app)) {
            guard case .keychainUnavailable = $0 as? PasswordStoreError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: dbURL), before, "the database is untouched")
        XCTAssertEqual(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app).allLogins().count, 1, "and opens once the Keychain does")
    }

    func testWrongKeyMovesTheDatabaseAsideAndKeepsTheKey() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: example, username: "a", password: "b")
        let original = try Data(contentsOf: dbURL)
        let otherKey = SymmetricKey(size: .bits256)
        let keys = InMemoryKeyStore(key: otherKey)
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        let aside = try XCTUnwrap(store.movedAside)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("passwords.unreadable-"))
        XCTAssertEqual(try Data(contentsOf: aside), original, "the unreadable database is kept as it was")
        XCTAssertTrue(try store.allLogins().isEmpty)
        XCTAssertEqual(keys.key.map { $0.withUnsafeBytes { Data($0) } }, otherKey.withUnsafeBytes { Data($0) },
                       "an existing key is never replaced")
        try store.add(origin: example, username: "new", password: "new")
        XCTAssertEqual(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app).allLogins().count, 1)
    }

    func testAppModeMissingKeyWithLoginsThrowsAndTouchesNothing() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: example, username: "a", password: "b")
        let before = try snapshot()
        let keys = InMemoryKeyStore()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)) {
            XCTAssertEqual($0 as? PasswordStoreError, .keyMissing)
        }
        XCTAssertNil(keys.key, "no key is created over a file that holds logins")
        XCTAssertEqual(try snapshot(), before, "the file is untouched and nothing was moved aside")
    }

    func testAppModeMissingKeyWithOnlyAKeyCheckThrows() throws {
        // Opened once (so it holds a key check) but never given a login.
        _ = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app)
        let before = try snapshot()
        let keys = InMemoryKeyStore()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)) {
            XCTAssertEqual($0 as? PasswordStoreError, .keyMissing)
        }
        XCTAssertNil(keys.key)
        XCTAssertEqual(try snapshot(), before)
    }

    func testFirstRunCreatesTheKeyAndTheFile() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertNotNil(keys.key)
        XCTAssertNil(store.movedAside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        try store.add(origin: example, username: "a", password: "b")
        XCTAssertEqual(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app).allLogins().count, 1)

        // A file that holds nothing (created, never set up) is a first run too.
        let emptyURL = dir.appendingPathComponent("empty.sqlite")
        try Data().write(to: emptyURL)
        let emptyKeys = InMemoryKeyStore()
        let empty = try PasswordStore(fileURL: emptyURL, keyStore: emptyKeys, mode: .app)
        XCTAssertNotNil(emptyKeys.key)
        XCTAssertNil(empty.movedAside)
    }

    func testStartOverKeepsTheOldFileAsideWithANewKey() throws {
        let oldKeys = InMemoryKeyStore()
        try PasswordStore(fileURL: dbURL, keyStore: oldKeys, mode: .app).add(origin: example, username: "a", password: "b")
        let original = try Data(contentsOf: dbURL)
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .appStartOver)
        let aside = try XCTUnwrap(store.movedAside)
        XCTAssertEqual(PasswordStore.setAsideCopies(of: dbURL), [aside])
        XCTAssertEqual(try Data(contentsOf: aside), original, "the old file is kept as it was")
        XCTAssertNotNil(keys.key, "a new key")
        XCTAssertNotEqual(keys.key.map { $0.withUnsafeBytes { Data($0) } }, oldKeys.key.map { $0.withUnsafeBytes { Data($0) } })
        XCTAssertTrue(try store.allLogins().isEmpty)
        try store.add(origin: example, username: "new", password: "new")
        XCTAssertNil(try store.recover(from: aside), "sealed with the old key")
        // The old file still opens with the old key.
        XCTAssertEqual(try PasswordStore(fileURL: aside, keyStore: oldKeys, mode: .app).allLogins().count, 1)
    }

    func testStartOverWithAUsableFileChangesNothing() throws {
        let keys = InMemoryKeyStore()
        try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app).add(origin: example, username: "a", password: "b")
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .appStartOver)
        XCTAssertNil(store.movedAside)
        XCTAssertEqual(try store.allLogins().count, 1)
    }

    func testDamagedFileIsMovedAsideOnlyWithAKey() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: dbURL)
        // Without a key a damaged file might hold logins: no key is created over it.
        let noKey = InMemoryKeyStore()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: noKey, mode: .app)) {
            XCTAssertEqual($0 as? PasswordStoreError, .keyMissing)
        }
        XCTAssertNil(noKey.key)
        XCTAssertEqual(try Data(contentsOf: dbURL), Data("not a database".utf8))

        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(key: SymmetricKey(size: .bits256)), mode: .app)
        XCTAssertNotNil(store.movedAside)
        try store.add(origin: example, username: "a", password: "b")
        XCTAssertEqual(try store.allLogins().count, 1)
    }

    // MARK: Existing-only (any process other than the app)

    func testExistingOnlyWithoutAKeyThrowsAndChangesNothing() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: example, username: "a", password: "b")
        let before = try snapshot()
        let keys = InMemoryKeyStore()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .keyMissing)
        }
        XCTAssertNil(keys.key, "no key is created")
        XCTAssertEqual(try snapshot(), before, "every file byte for byte, and no file added or moved")
    }

    func testExistingOnlyWithoutAFileCreatesNothing() throws {
        let keys = InMemoryKeyStore(key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .fileMissing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "not even the folder")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .fileMissing)
        }
        XCTAssertEqual(try snapshot(), [:])
        // And with no key either.
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .existingOnly))
        XCTAssertEqual(try snapshot(), [:])
    }

    func testExistingOnlyWithAWrongKeyMovesNothing() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: example, username: "a", password: "b")
        let before = try snapshot()
        let keys = InMemoryKeyStore(key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .wrongKey)
        }
        XCTAssertEqual(try snapshot(), before)
        XCTAssertTrue(PasswordStore.setAsideCopies(of: dbURL).isEmpty)
    }

    func testExistingOnlyLeavesADamagedFileAlone() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: dbURL)
        let before = try snapshot()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(key: SymmetricKey(size: .bits256)), mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .unrecognizedFile)
        }
        XCTAssertEqual(try snapshot(), before)
    }

    func testExistingOnlyDoesntConvertAnOlderFile() throws {
        let keys = InMemoryKeyStore()
        try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app).add(origin: example, username: "a", password: "b")
        try makeRollbackJournal(dbURL)
        let before = try snapshot()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .notSetUp)
        }
        XCTAssertEqual(try snapshot(), before, "still the older format: only the app converts it")
    }

    func testExistingOnlyDoesntSetUpAFileTheAppHasnt() throws {
        // A WAL file with the tables but no key check yet: the app writes that, not another process.
        let keys = InMemoryKeyStore(key: SymmetricKey(size: .bits256))
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let queue = try DatabasePool(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL); CREATE TABLE login (id TEXT)")
        }
        try queue.close()
        // As if the app had opened it (it makes the lock file), so the key check is what's missing.
        FileManager.default.createFile(atPath: StoreLock.url(for: dbURL).path, contents: nil)
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .notSetUp)
        }
    }

    func testExistingOnlyCantRestoreOrBackUp() throws {
        let keys = InMemoryKeyStore()
        let app = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        try app.add(origin: example, username: "a", password: "b")
        let agent = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)
        XCTAssertNil(agent.movedAside)
        XCTAssertEqual(try agent.allLogins().count, 1)
        XCTAssertThrowsError(try agent.recover(from: dbURL)) { XCTAssertEqual($0 as? PasswordStoreError, .appOnly) }
        XCTAssertThrowsError(try agent.backUp(reason: "x")) { XCTAssertEqual($0 as? PasswordStoreError, .appOnly) }
    }

    // MARK: Two processes, WAL

    func testAppAndExistingOnlyShareTheFile() throws {
        let keys = InMemoryKeyStore()
        let app = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        let agent = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)
        let a = try app.add(origin: example, username: "from-app", password: "1")
        XCTAssertEqual(try agent.login(id: a.id)?.password, "1", "the other store reads the app's write")
        let b = try agent.add(origin: other, username: "from-agent", password: "2")
        XCTAssertEqual(try app.login(id: b.id)?.password, "2", "and the app reads the other's")
        try agent.delete(id: a.id)
        XCTAssertNil(try app.login(id: a.id))
    }

    func testConcurrentWritesFromTwoStoresDontFailBusy() throws {
        let keys = InMemoryKeyStore()
        let stores = [try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app),
                      try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)]
        let failures = OSAllocatedUnfairLock(initialState: [String]())
        DispatchQueue.concurrentPerform(iterations: 4) { i in
            let store = stores[i % 2]
            for j in 0..<40 {
                do {
                    let login = try store.save(origin: Origin(string: "https://w\(i).example")!, username: "u\(j)", password: "p\(j)")
                    try store.markUsed(id: login.id)
                    _ = try store.allLogins()
                } catch {
                    failures.withLock { $0.append(String(describing: error)) }
                }
            }
        }
        XCTAssertEqual(failures.withLock { $0 }, [])
        XCTAssertEqual(try stores[0].allLogins().count, 160)
        XCTAssertEqual(try stores[1].allLogins().count, 160)
    }

    func testPragmasAndWALOnEveryConnection() throws {
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app)
        for read in [true, false] {
            let values = try (read ? store.database.read : store.database.write) { db in
                [try String.fetchOne(db, sql: "PRAGMA journal_mode"),
                 try String.fetchOne(db, sql: "PRAGMA secure_delete"),
                 try String.fetchOne(db, sql: "PRAGMA trusted_schema"),
                 try String.fetchOne(db, sql: "PRAGMA busy_timeout")]
            }
            XCTAssertEqual(values, ["wal", "1", "0", read ? "10000" : "5000"], read ? "reader" : "writer")
        }
        XCTAssertTrue(PasswordStore.isWAL(dbURL))
    }

    func testOlderRollbackJournalFileConvertsToWALAndKeepsEveryLogin() throws {
        let keys = InMemoryKeyStore()
        var saved: [Login] = []
        do {
            let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
            for i in 0..<50 { saved.append(try store.add(origin: Origin(string: "https://s\(i).example")!, username: "u\(i)", password: "p\(i)")) }
            try store.setNeverSave(other)
            try store.close()
        }
        // As the store wrote it before WAL (a DatabaseQueue in rollback-journal mode).
        try makeRollbackJournal(dbURL)
        XCTAssertFalse(PasswordStore.isWAL(dbURL))
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertNil(store.movedAside)
        XCTAssertTrue(PasswordStore.isWAL(dbURL), "converted to WAL")
        XCTAssertEqual(try store.health(), PasswordStore.Health(rows: 50, unreadable: 0))
        XCTAssertEqual(Set(try store.allLogins().map(\.id)), Set(saved.map(\.id)))
        XCTAssertTrue(try store.isNeverSave(other))
        // And now another process can open it too.
        XCTAssertEqual(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly).allLogins().count, 50)
    }

    func testMoveAsideKeepsRowsStillInTheWAL() throws {
        let key = SymmetricKey(size: .bits256)
        // A store with rows only in its WAL, as a crash leaves it: copied while still open.
        let source = dir.appendingPathComponent("live", isDirectory: true)
        let live = source.appendingPathComponent("passwords.sqlite")
        let store = try PasswordStore(fileURL: live, keyStore: InMemoryKeyStore(key: key), mode: .app)
        for i in 0..<20 { try store.add(origin: Origin(string: "https://s\(i).example")!, username: "u\(i)", password: "p\(i)") }
        for (from, to) in zip([live] + SecureFile.sideFiles(of: live), [dbURL] + SecureFile.sideFiles(of: dbURL))
        where FileManager.default.fileExists(atPath: from.path) {
            try FileManager.default.copyItem(at: from, to: to)
        }
        try store.close()
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        XCTAssertGreaterThan(try Data(contentsOf: wal).count, 0, "the rows are in the WAL")

        let aside = try SecureFile.moveAside(dbURL, reason: "unreadable")
        XCTAssertFalse(FileManager.default.fileExists(atPath: wal.path), "the WAL went with it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: aside.path + "-wal"))
        XCTAssertEqual(try PasswordStore(fileURL: aside, keyStore: InMemoryKeyStore(key: key), mode: .app).allLogins().count, 20,
                       "the copy set aside has every row")
    }

    func testWrongKeyOnACrashedWALFileKeepsEveryRowInTheCopy() throws {
        let key = SymmetricKey(size: .bits256)
        let source = dir.appendingPathComponent("live", isDirectory: true)
        let live = source.appendingPathComponent("passwords.sqlite")
        let store = try PasswordStore(fileURL: live, keyStore: InMemoryKeyStore(key: key), mode: .app)
        for i in 0..<20 { try store.add(origin: Origin(string: "https://s\(i).example")!, username: "u\(i)", password: "p\(i)") }
        for (from, to) in zip([live] + SecureFile.sideFiles(of: live), [dbURL] + SecureFile.sideFiles(of: dbURL))
        where FileManager.default.fileExists(atPath: from.path) {
            try FileManager.default.copyItem(at: from, to: to)
        }
        try store.close()
        let other = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(key: SymmetricKey(size: .bits256)), mode: .app)
        let aside = try XCTUnwrap(other.movedAside)
        XCTAssertTrue(try other.allLogins().isEmpty)
        let recovered = try PasswordStore(fileURL: aside, keyStore: InMemoryKeyStore(key: key), mode: .app)
        XCTAssertEqual(try recovered.allLogins().count, 20)
    }

    func testBackupIsOneSelfContainedFile() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        for i in 0..<10 { try store.add(origin: Origin(string: "https://s\(i).example")!, username: "u\(i)", password: "p\(i)") }
        let backup = try store.backUp(reason: "before-restore")
        XCTAssertEqual(try permissions(backup), 0o600)
        for side in SecureFile.sideFiles(of: backup) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: side.path), "\(side.lastPathComponent) isn't needed")
        }
        // Copied on its own somewhere else, it still holds every login.
        let elsewhere = dir.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let copy = elsewhere.appendingPathComponent("passwords.sqlite")
        try FileManager.default.copyItem(at: backup, to: copy)
        XCTAssertEqual(try PasswordStore(fileURL: copy, keyStore: keys, mode: .app).allLogins().count, 10)
    }

    func testTamperedRowsAreSkipped() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        let bank = try store.add(origin: Origin(string: "https://bank.com")!, username: "me", password: "bank-secret")
        try store.add(origin: other, username: "me", password: "other")
        // An attacker with write access to the file points the bank login at their own site.
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE login SET origin = 'https://evil.example' WHERE id = ?", arguments: [bank.id.uuidString])
        }
        try queue.close()
        let reopened = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertTrue(try reopened.logins(for: Origin(string: "https://evil.example")!).isEmpty, "the moved row doesn't open")
        XCTAssertEqual(try reopened.unreadableCount(), 1)
        XCTAssertEqual(try reopened.allLogins().count, 1)
        XCTAssertEqual(try reopened.health(), PasswordStore.Health(rows: 2, unreadable: 1), "counted, never silently dropped")
    }

    // MARK: Reopening (an app update relaunches on the same file and key)

    func testReopeningKeepsEveryLoginReadable() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        let origins = ["https://example.com", "https://EXAMPLE.com.", "https://bücher.example", "http://localhost:3000",
                       "https://[::1]:8443", "http://10.0.0.5", "https://login.microsoftonline.com:443",
                       "https://dev.azure.com", "https://a.b.c.d.example.co.uk"].map { Origin(string: $0)! }
        var saved: [Login] = []
        for i in 0..<300 {
            saved.append(try store.add(origin: origins[i % origins.count], username: "user\(i)", password: "pw-\(i)",
                                       date: Date(timeIntervalSince1970: 1_600_000_000 + Double(i))))
        }
        // A new process: the same file and the same Keychain key.
        let reopened = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertNil(reopened.movedAside)
        XCTAssertEqual(try reopened.health(), PasswordStore.Health(rows: 300, unreadable: 0))
        XCTAssertEqual(try reopened.allLogins().count, 300)
        for login in saved {
            XCTAssertTrue(try reopened.logins(for: login.origin).contains { $0.login.id == login.id && $0.kind == .exact },
                          "\(login.origin) is offered after reopening")
        }
    }

    func testLockedDatabaseIsLeftAloneNotMovedAside() throws {
        let keys = InMemoryKeyStore()
        try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app).add(origin: example, username: "a", password: "b")
        // An older copy of the app (rollback journal) still quitting holds a write lock: in that
        // mode it blocks readers too. (In WAL mode a writer doesn't block opening; see
        // testAWriterInAnotherProcessDoesntBlockOpening.)
        try makeRollbackJournal(dbURL)
        var config = Configuration()
        config.allowsUnsafeTransactions = true
        let other = try DatabaseQueue(path: dbURL.path, configuration: config)
        try other.writeWithoutTransaction { db in try db.execute(sql: "BEGIN EXCLUSIVE") }
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)) {
            guard case .databaseUnavailable = $0 as? PasswordStoreError else { return XCTFail("\($0)") }
        }
        XCTAssertTrue(PasswordStore.setAsideCopies(of: dbURL).isEmpty, "nothing was moved aside")
        try other.writeWithoutTransaction { db in try db.execute(sql: "COMMIT") }
        try other.close()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertNil(store.movedAside)
        XCTAssertEqual(try store.allLogins().count, 1)
    }

    func testAWriterInAnotherProcessDoesntBlockOpening() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        try store.add(origin: example, username: "a", password: "b")
        var config = Configuration()
        config.allowsUnsafeTransactions = true
        let other = try DatabaseQueue(path: dbURL.path, configuration: config)
        // Another process is in the middle of a write.
        try other.writeWithoutTransaction { db in try db.execute(sql: "BEGIN IMMEDIATE; INSERT INTO neverSave VALUES ('https://x.example', 0)") }
        XCTAssertEqual(try store.allLogins().count, 1, "reads don't wait for the other writer")
        // Writes, and opening another store, wait their turn (the busy timeout) rather than fail.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            try? other.writeWithoutTransaction { db in try db.execute(sql: "COMMIT") }
        }
        try store.add(origin: www, username: "c", password: "d")
        XCTAssertEqual(try store.allLogins().count, 2)
        try other.writeWithoutTransaction { db in try db.execute(sql: "BEGIN IMMEDIATE") }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            try? other.writeWithoutTransaction { db in try db.execute(sql: "COMMIT") }
        }
        let reopened = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertNil(reopened.movedAside)
        XCTAssertEqual(try reopened.allLogins().count, 2)
        XCTAssertTrue(try reopened.isNeverSave(Origin(string: "https://x.example")!))
        XCTAssertTrue(PasswordStore.setAsideCopies(of: dbURL).isEmpty)
        try other.close()
    }

    func testStartOverWithAKeyThatCantBeSavedTouchesNothing() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: example, username: "a", password: "b")
        let before = try Data(contentsOf: dbURL)
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: NoKeyRefusingSaves(), mode: .appStartOver)) {
            guard case .keychainUnavailable = $0 as? PasswordStoreError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: dbURL), before, "the file stays where it is")
        XCTAssertTrue(PasswordStore.setAsideCopies(of: dbURL).isEmpty)
    }

    // MARK: Recovering a copy set aside

    func testRecoverAddsLoginsFromACopySetAsideWithoutLosingAny() throws {
        let keys = InMemoryKeyStore()
        let first = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        for i in 0..<5 { try first.add(origin: Origin(string: "https://site\(i).example")!, username: "u\(i)", password: "old-\(i)") }
        try first.setNeverSave(other)
        try first.close()
        // The file was moved aside (as an unreadable file would be) and a new one started.
        let aside = dir.appendingPathComponent("passwords.unreadable-100.sqlite")
        try moveDatabase(at: dbURL, to: aside)
        let asideBytes = try Data(contentsOf: aside)
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertEqual(PasswordStore.setAsideCopies(of: dbURL), [aside])
        try store.add(origin: Origin(string: "https://site0.example")!, username: "u0", password: "newer")
        try store.add(origin: Origin(string: "https://fresh.example")!, username: "f", password: "f")

        let result = try XCTUnwrap(try store.recover(from: aside))
        XCTAssertEqual(result.restored, 4)
        XCTAssertEqual(result.alreadyThere, 1, "site0/u0 keeps the store's newer password")
        XCTAssertEqual(result.unreadable, 0)
        let backup = try XCTUnwrap(result.backup)
        XCTAssertEqual(try permissions(backup), 0o600)
        XCTAssertEqual(try PasswordStore(fileURL: backup, keyStore: keys, mode: .app).allLogins().count, 2, "the backup is the store before restoring")

        let all = try store.allLogins()
        XCTAssertEqual(all.count, 6)
        XCTAssertEqual(all.first { $0.username == "u0" }?.password, "newer")
        XCTAssertTrue(try store.isNeverSave(other))
        XCTAssertEqual(try Data(contentsOf: aside), asideBytes, "the copy is only read")

        let again = try XCTUnwrap(try store.recover(from: aside))
        XCTAssertEqual(again.restored, 0)
        XCTAssertNil(again.backup, "nothing to add, nothing backed up")
        XCTAssertEqual(try store.allLogins().count, 6)
    }

    func testEachCopyIsRecoveredOnceAndNewestFirst() throws {
        let keys = InMemoryKeyStore()
        let site = Origin(string: "https://site.example")!
        let older = dir.appendingPathComponent("passwords.unreadable-100.sqlite")
        let newer = dir.appendingPathComponent("passwords.unreadable-200.sqlite")
        let sameSecond = dir.appendingPathComponent("passwords.unreadable-200-2.sqlite")
        for (copy, password) in [(older, "old"), (newer, "new"), (sameSecond, "newest")] {
            let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
            try store.add(origin: site, username: "me", password: password)
            try store.close()
            try moveDatabase(at: dbURL, to: copy)
        }
        XCTAssertEqual(PasswordStore.setAsideCopies(of: dbURL), [sameSecond, newer, older], "newest first")

        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        for copy in PasswordStore.setAsideCopies(of: dbURL) where try !store.wasRecovered(copy) {
            _ = try store.recover(from: copy)
        }
        XCTAssertEqual(try store.allLogins().map(\.password), ["newest"], "the newest copy's password wins")
        XCTAssertTrue(try PasswordStore.setAsideCopies(of: dbURL).allSatisfy { try store.wasRecovered($0) })

        // Deleted after it was restored: the next launch leaves it deleted.
        try store.delete(id: try XCTUnwrap(store.allLogins().first).id)
        let relaunched = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertTrue(try PasswordStore.setAsideCopies(of: dbURL).allSatisfy { try relaunched.wasRecovered($0) })
        XCTAssertTrue(try relaunched.allLogins().isEmpty)
    }

    func testRecoverIgnoresACopySealedWithAnotherKey() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: example, username: "a", password: "b")
        let aside = dir.appendingPathComponent("passwords.unreadable-100.sqlite")
        try moveDatabase(at: dbURL, to: aside)
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app)
        XCTAssertNil(try store.recover(from: aside))
        XCTAssertTrue(try store.allLogins().isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains("before-restore") }, [])
    }

    // MARK: The lock: nothing is moved aside while another store has the file open

    func testMoveAsideWaitsUntilNoOtherStoreHasTheFileOpen() throws {
        let oldKeys = InMemoryKeyStore()
        let holder = try PasswordStore(fileURL: dbURL, keyStore: oldKeys, mode: .app)
        try holder.add(origin: example, username: "a", password: "b")
        let agent = try PasswordStore(fileURL: dbURL, keyStore: oldKeys, mode: .existingOnly)
        let before = try snapshot()
        let newKeys = InMemoryKeyStore(key: SymmetricKey(size: .bits256))
        for mode in [PasswordStore.OpenMode.app, .appStartOver] {
            XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: newKeys, mode: mode)) {
                XCTAssertEqual($0 as? PasswordStoreError, .databaseUnavailable("another process has the passwords file open"))
            }
        }
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .appStartOver)) {
            XCTAssertEqual($0 as? PasswordStoreError, .databaseUnavailable("another process has the passwords file open"))
        }
        XCTAssertEqual(try snapshot(), before, "nothing moved while two stores had it open")
        try holder.close()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: newKeys, mode: .app), "the agent still has it open")
        XCTAssertEqual(try agent.allLogins().count, 1, "and keeps working")
        try agent.close()
        let replaced = try PasswordStore(fileURL: dbURL, keyStore: newKeys, mode: .app)
        XCTAssertNotNil(replaced.movedAside, "once nobody has it open")
        XCTAssertEqual(try permissions(StoreLock.url(for: dbURL)), 0o600, "the lock file is owner-only")
    }

    func testAStoreLetsGoOfTheLockWhenItCloses() throws {
        do {
            let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app)
            let probe = try StoreLock(for: dbURL, create: false)
            XCTAssertFalse(probe.lockExclusively(), "held shared while open")
            try store.close()
        }
        XCTAssertTrue(try StoreLock(for: dbURL, create: false).lockExclusively(), "released on close")
        do { _ = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(key: SymmetricKey(size: .bits256)), mode: .app) }
        catch {} // a different key: moved aside, then the store is released when it goes away
        XCTAssertTrue(try StoreLock(for: dbURL, create: false).lockExclusively(), "released when deallocated")
    }

    func testAnotherLaunchThatAlreadyReplacedTheFileIsNotMovedAgain() throws {
        // A file sealed with a key that's gone; two launches both judged it wrong-key. The other
        // launch replaced it first, between our look and our move.
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: example, username: "a", password: "b")
        let keys = InMemoryKeyStore(key: SymmetricKey(size: .bits256))
        var otherLaunch: PasswordStore.OpenMode? = .app
        PasswordStore.testHook = { stage in
            guard stage == "app.beforeExclusive", let mode = otherLaunch else { return }
            otherLaunch = nil
            // In the moment `flock` lets go of our shared lock to take it exclusively, the other
            // launch takes it, moves the old file aside and starts a new one.
            let other = try! PasswordStore(fileURL: self.dbURL, keyStore: keys, mode: mode)
            XCTAssertNotNil(other.movedAside)
            try! other.add(origin: self.example, username: "fresh", password: "fresh")
            try! other.close()
        }
        let store: PasswordStore
        do {
            store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        } catch {
            return XCTFail("\(error)")
        }
        XCTAssertNil(store.movedAside, "judged again under the exclusive lock: the new file is fine")
        XCTAssertEqual(try store.allLogins().map(\.username), ["fresh"], "the other launch's new file is kept")
        XCTAssertEqual(PasswordStore.setAsideCopies(of: dbURL).count, 1, "only the original was moved aside, once")
    }

    func testExistingOnlyKeepsTheConnectionItChecked() throws {
        let keys = InMemoryKeyStore()
        try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app).add(origin: example, username: "a", password: "b")
        // Someone replaces the file (by hand: the app can't while we hold the lock) between our
        // look and our open.
        let foreign = dir.appendingPathComponent("foreign", isDirectory: true)
        let foreignURL = foreign.appendingPathComponent("passwords.sqlite")
        try PasswordStore(fileURL: foreignURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: other, username: "x", password: "y")
        PasswordStore.testHook = { stage in
            guard stage == "existingOnly.inspected" else { return }
            try! FileManager.default.removeItem(at: self.dbURL)
            try! FileManager.default.copyItem(at: foreignURL, to: self.dbURL)
        }
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .databaseUnavailable("the passwords file changed while it was being opened"))
        }
        PasswordStore.testHook = nil
        // Same inode, other contents (written in place) is caught by the key check on the kept
        // connection.
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .wrongKey)
        }
    }

    func testExistingOnlyRejectsACrashedWALFileWithoutChangingIt() throws {
        let key = SymmetricKey(size: .bits256)
        let live = dir.appendingPathComponent("live", isDirectory: true).appendingPathComponent("passwords.sqlite")
        let store = try PasswordStore(fileURL: live, keyStore: InMemoryKeyStore(key: key), mode: .app)
        for i in 0..<20 { try store.add(origin: Origin(string: "https://s\(i).example")!, username: "u\(i)", password: "p\(i)") }
        // As a crash leaves it: committed rows only in the -wal.
        for (from, to) in zip([live, StoreLock.url(for: live)] + SecureFile.sideFiles(of: live),
                              [dbURL, StoreLock.url(for: dbURL)] + SecureFile.sideFiles(of: dbURL))
        where FileManager.default.fileExists(atPath: from.path) {
            try FileManager.default.copyItem(at: from, to: to)
        }
        try store.close()
        XCTAssertGreaterThan(try Data(contentsOf: URL(fileURLWithPath: dbURL.path + "-wal")).count, 0)
        let before = try snapshot()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(key: SymmetricKey(size: .bits256)), mode: .existingOnly)) {
            XCTAssertEqual($0 as? PasswordStoreError, .wrongKey)
        }
        XCTAssertEqual(try snapshot(), before, "not checkpointed: the file and its -wal are as they were")
        // With the right key it opens, and sees the rows in the -wal.
        XCTAssertEqual(try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(key: key), mode: .existingOnly).allLogins().count, 20)
    }

    func testRecoveryLetsALoginSavedMeanwhileWin() throws {
        let keys = InMemoryKeyStore()
        let first = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        try first.add(origin: example, username: "me", password: "old")
        try first.add(origin: other, username: "me", password: "other")
        try first.close()
        let aside = dir.appendingPathComponent("passwords.unreadable-100.sqlite")
        try moveDatabase(at: dbURL, to: aside)
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        let agent = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)
        PasswordStore.testHook = { stage in
            guard stage == "recover.beforeWrite" else { return }
            // Another process saves the same login, with a new id, after recovery looked.
            try! agent.save(origin: self.example, username: "me", password: "current")
        }
        let result = try XCTUnwrap(try store.recover(from: aside))
        XCTAssertEqual(result.restored, 1)
        XCTAssertEqual(result.alreadyThere, 1)
        let mine = try store.allLogins().filter { $0.origin == example }
        XCTAssertEqual(mine.map(\.password), ["current"], "one login, the one saved meanwhile")
    }

    func testAMoveAsideThatFailsIsPutBackOrSaysWhereEverythingIs() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        try store.add(origin: example, username: "a", password: "b")
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        struct Refused: Error {}
        // The -wal won't move: everything is put back.
        XCTAssertThrowsError(try SecureFile.moveAside(dbURL, reason: "unreadable", mover: { from, to in
            if from == wal { throw Refused() }
            try FileManager.default.moveItem(at: from, to: to)
        })) { XCTAssertTrue($0 is Refused, "\($0)") }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbURL.path))
        XCTAssertTrue(PasswordStore.setAsideCopies(of: dbURL).isEmpty)
        XCTAssertEqual(try store.allLogins().count, 1)

        // The -wal won't move and the main file won't move back: the error says where each is.
        var movedBack = false
        XCTAssertThrowsError(try SecureFile.moveAside(dbURL, reason: "unreadable", mover: { from, to in
            if from == wal { throw Refused() }
            if to == self.dbURL { movedBack = true; throw Refused() }
            try FileManager.default.moveItem(at: from, to: to)
        })) { error in
            guard let incomplete = error as? Passwords.SecureFile.IncompleteMove else { return XCTFail("\(error)") }
            let aside = try! XCTUnwrap(PasswordStore.setAsideCopies(of: self.dbURL).first)
            XCTAssertTrue(incomplete.description.contains("passwords.sqlite is at \(aside.path)"), incomplete.description)
            XCTAssertTrue(incomplete.description.contains("passwords.sqlite-wal is at \(wal.path)"), incomplete.description)
        }
        XCTAssertTrue(movedBack)
    }

    // MARK: A real second process

    /// Runs a Python script (the system's, with its own SQLite) as a child process. Returns once
    /// it prints "ready".
    private func child(_ script: String, _ args: [String]) throws -> (Process, Pipe) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-I", "-c", script] + args
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        var text = ""
        while !text.contains("ready") {
            let data = output.fileHandleForReading.availableData
            guard !data.isEmpty else { break }
            text += String(decoding: data, as: UTF8.self)
        }
        XCTAssertTrue(text.contains("ready"), text)
        return (process, input)
    }

    func testAnotherProcessHoldingTheLockPreventsAMoveAside() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app).add(origin: example, username: "a", password: "b")
        let (process, input) = try child("""
            import fcntl, sys
            f = open(sys.argv[1], 'r')
            fcntl.flock(f, fcntl.LOCK_SH)
            print('ready', flush=True)
            sys.stdin.read()
            """, [StoreLock.url(for: dbURL).path])
        let before = try snapshot()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .appStartOver)) {
            XCTAssertEqual($0 as? PasswordStoreError, .databaseUnavailable("another process has the passwords file open"))
        }
        XCTAssertEqual(try snapshot(), before)
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .appStartOver)
        XCTAssertNotNil(store.movedAside, "once the other process is gone")
    }

    func testWritesFromAnotherProcessAndThisOneDontFailBusy() throws {
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore(), mode: .app)
        let (process, input) = try child("""
            import sqlite3, sys
            db = sqlite3.connect(sys.argv[1], timeout=5, isolation_level=None)
            print('ready', flush=True)
            for i in range(200):
                db.execute('BEGIN IMMEDIATE')
                db.execute('INSERT INTO neverSave (origin, created) VALUES (?, 0)', ('https://p%d.example' % i,))
                db.execute('COMMIT')
            print('done', flush=True)
            sys.stdin.read()
            """, [dbURL.path])
        for i in 0..<100 { try store.save(origin: Origin(string: "https://s\(i).example")!, username: "u", password: "p\(i)") }
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "the other process's writes all went through")
        XCTAssertEqual(try store.allLogins().count, 100)
        XCTAssertEqual(try store.neverSaveOrigins().count, 200)
    }

    // MARK: Durability and leftovers

    private func synchronous(_ store: PasswordStore) throws -> Int? {
        try store.database.writeWithoutTransaction { db in try Int.fetchOne(db, sql: "PRAGMA synchronous") }
    }

    func testEveryCommitIsSyncedFully() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertEqual(try synchronous(store), 2, "FULL on a fresh store's writer, not GRDB's WAL default NORMAL")
        try store.add(origin: example, username: "a", password: "b")
        XCTAssertEqual(try synchronous(PasswordStore(fileURL: dbURL, keyStore: keys, mode: .existingOnly)), 2, "and on another process's queue")
        try store.close()

        try makeRollbackJournal(dbURL)
        let converted = try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app)
        XCTAssertTrue(PasswordStore.isWAL(dbURL))
        XCTAssertEqual(try synchronous(converted), 2, "FULL after converting an older file to WAL")
    }

    func testAWALLeftWithoutItsDatabaseIsNeverAFirstRun() throws {
        let key = SymmetricKey(size: .bits256)
        // A store with committed rows only in its -wal, as a crash leaves it...
        let live = dir.appendingPathComponent("live", isDirectory: true).appendingPathComponent("passwords.sqlite")
        let store = try PasswordStore(fileURL: live, keyStore: InMemoryKeyStore(key: key), mode: .app)
        for i in 0..<5 { try store.add(origin: Origin(string: "https://s\(i).example")!, username: "u\(i)", password: "p\(i)") }
        for (from, to) in zip([live, StoreLock.url(for: live)] + SecureFile.sideFiles(of: live),
                              [dbURL, StoreLock.url(for: dbURL)] + SecureFile.sideFiles(of: dbURL))
        where FileManager.default.fileExists(atPath: from.path) {
            try FileManager.default.copyItem(at: from, to: to)
        }
        try store.close()
        // ...then its main file moved away (an interrupted move aside), the -wal left behind.
        try FileManager.default.moveItem(at: dbURL, to: dir.appendingPathComponent("passwords.unreadable-1.sqlite"))
        let wal = URL(fileURLWithPath: dbURL.path + "-wal")
        XCTAssertGreaterThan(try Data(contentsOf: wal).count, 0)
        let before = try snapshot()
        for (mode, keys) in [(PasswordStore.OpenMode.app, InMemoryKeyStore()), (.app, InMemoryKeyStore(key: key)),
                             (.appStartOver, InMemoryKeyStore()), (.existingOnly, InMemoryKeyStore(key: key))] {
            let hadKey = keys.key != nil
            XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: mode), "\(mode)") { error in
                guard case .orphanedSideFiles(let paths) = error as? PasswordStoreError else { return XCTFail("\(mode): \(error)") }
                XCTAssertTrue(paths.contains(wal.path), "\(paths)")
            }
            XCTAssertEqual(keys.key != nil, hadKey, "\(mode): no key created")
        }
        XCTAssertEqual(try snapshot(), before, "no new database, and the -wal is byte for byte as it was")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbURL.path))
    }

    func testAFirstRunWithNoKeyCreatesNoKeyOverALeftoverWAL() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: URL(fileURLWithPath: dbURL.path + "-wal"))
        let keys = InMemoryKeyStore()
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: keys, mode: .app))
        XCTAssertNil(keys.key)
    }

    func testKeychainKeyStoreForPasswordsIsSeparate() {
        let store = PasswordStore.keychainKeyStore()
        XCTAssertEqual(store.service, "com.scottsmith.ismith.passwords-key")
        XCTAssertNotEqual(store.service, KeychainKeyStore.vaultService)
        XCTAssertEqual(store.label, "iSmith passwords key")
    }
}

/// A Keychain with no key that refuses to save one.
private struct NoKeyRefusingSaves: KeyStore {
    struct Refused: Error {}
    func loadKey() throws -> SymmetricKey? { nil }
    func saveKey(_ key: SymmetricKey) throws { throw Refused() }
}

private struct FailingKeyStore: KeyStore {
    struct Locked: Error {}
    func loadKey() throws -> SymmetricKey? { throw Locked() }
    func saveKey(_ key: SymmetricKey) throws { throw Locked() }
}
