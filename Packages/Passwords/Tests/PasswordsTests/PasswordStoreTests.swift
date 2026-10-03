import CryptoKit
import GRDB
@testable import Passwords
import SignInSync
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
        try? FileManager.default.removeItem(at: dir)
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
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys)
        XCTAssertNotNil(keys.key, "a first run creates a key")
        let login = try store.add(origin: example, username: "scott@example.com", password: "Correct-Horse-Battery-77")

        let raw = try Data(contentsOf: dbURL)
        for secret in ["scott@example.com", "Correct-Horse-Battery-77", "Correct-Horse"] {
            XCTAssertNil(raw.range(of: Data(secret.utf8)), "\(secret) is not in the file in the clear")
        }
        XCTAssertNotNil(raw.range(of: Data("https://example.com".utf8)), "origins are in the clear, for matching")
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
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let a = try store.add(origin: example, username: "alice", password: "pw-a-1", date: t0)
        let b = try store.add(origin: example, username: "bob", password: "pw-b-1", date: t0)
        let c = try store.add(origin: other, username: "alice", password: "pw-c-1", date: t0)
        XCTAssertThrowsError(try store.add(origin: example, username: "alice", password: "x")) {
            XCTAssertEqual($0 as? PasswordStoreError, .duplicate)
        }

        // Reopened, as on the next launch.
        let reopened = try PasswordStore(fileURL: dbURL, keyStore: keys)
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
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore())
        try store.add(origin: example, username: "Scott.Smith", password: "findme-not")
        try store.add(origin: other, username: "someone", password: "x-123")
        XCTAssertEqual(try store.search("EXAMPLE").count, 1)
        XCTAssertEqual(try store.search("smith").count, 1)
        XCTAssertEqual(try store.search("findme").count, 0, "passwords are never searched")
        XCTAssertEqual(try store.search("  ").count, 2)
    }

    func testLoginsForOriginAndLastUsed() throws {
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore())
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
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore())
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
        try PasswordStore(fileURL: dbURL, keyStore: keys).add(origin: example, username: "a", password: "b")
        let before = try Data(contentsOf: dbURL)
        XCTAssertThrowsError(try PasswordStore(fileURL: dbURL, keyStore: FailingKeyStore())) {
            guard case .keychainUnavailable = $0 as? PasswordStoreError else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try Data(contentsOf: dbURL), before, "the database is untouched")
        XCTAssertEqual(try PasswordStore(fileURL: dbURL, keyStore: keys).allLogins().count, 1, "and opens once the Keychain does")
    }

    func testWrongKeyMovesTheDatabaseAsideAndKeepsTheKey() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore()).add(origin: example, username: "a", password: "b")
        let original = try Data(contentsOf: dbURL)
        let otherKey = SymmetricKey(size: .bits256)
        let keys = InMemoryKeyStore(key: otherKey)
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys)
        let aside = try XCTUnwrap(store.movedAside)
        XCTAssertTrue(aside.lastPathComponent.hasPrefix("passwords.unreadable-"))
        XCTAssertEqual(try Data(contentsOf: aside), original, "the unreadable database is kept as it was")
        XCTAssertTrue(try store.allLogins().isEmpty)
        XCTAssertEqual(keys.key.map { $0.withUnsafeBytes { Data($0) } }, otherKey.withUnsafeBytes { Data($0) },
                       "an existing key is never replaced")
        try store.add(origin: example, username: "new", password: "new")
        XCTAssertEqual(try PasswordStore(fileURL: dbURL, keyStore: keys).allLogins().count, 1)
    }

    func testMissingKeyWithSavedLoginsMovesTheDatabaseAside() throws {
        try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore()).add(origin: example, username: "a", password: "b")
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys)
        XCTAssertNotNil(store.movedAside)
        XCTAssertNotNil(keys.key)
        XCTAssertTrue(try store.allLogins().isEmpty)
    }

    func testDamagedFileIsMovedAside() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not a database".utf8).write(to: dbURL)
        let store = try PasswordStore(fileURL: dbURL, keyStore: InMemoryKeyStore())
        XCTAssertNotNil(store.movedAside)
        try store.add(origin: example, username: "a", password: "b")
        XCTAssertEqual(try store.allLogins().count, 1)
    }

    func testTamperedRowsAreSkipped() throws {
        let keys = InMemoryKeyStore()
        let store = try PasswordStore(fileURL: dbURL, keyStore: keys)
        let bank = try store.add(origin: Origin(string: "https://bank.com")!, username: "me", password: "bank-secret")
        try store.add(origin: other, username: "me", password: "other")
        // An attacker with write access to the file points the bank login at their own site.
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try db.execute(sql: "UPDATE login SET origin = 'https://evil.example' WHERE id = ?", arguments: [bank.id.uuidString])
        }
        try queue.close()
        let reopened = try PasswordStore(fileURL: dbURL, keyStore: keys)
        XCTAssertTrue(try reopened.logins(for: Origin(string: "https://evil.example")!).isEmpty, "the moved row doesn't open")
        XCTAssertEqual(try reopened.unreadableCount(), 1)
        XCTAssertEqual(try reopened.allLogins().count, 1)
    }

    func testKeychainKeyStoreForPasswordsIsSeparate() {
        let store = PasswordStore.keychainKeyStore()
        XCTAssertEqual(store.service, "com.scottsmith.ismith.passwords-key")
        XCTAssertNotEqual(store.service, KeychainKeyStore.vaultService)
        XCTAssertEqual(store.label, "iSmith passwords key")
    }
}

private struct FailingKeyStore: KeyStore {
    struct Locked: Error {}
    func loadKey() throws -> SymmetricKey? { throw Locked() }
    func saveKey(_ key: SymmetricKey) throws { throw Locked() }
}
