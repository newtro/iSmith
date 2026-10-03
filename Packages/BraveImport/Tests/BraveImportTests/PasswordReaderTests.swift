@testable import BraveImport
import SQLite3
import XCTest

/// Passwords from fixture login databases built with Chromium's schema and Brave's encryption,
/// with a test Safe Storage password. Nothing here reads the real Keychain or Brave's files.
final class PasswordReaderTests: XCTestCase {
    private var profileDir: URL!
    private var tempDir: URL!
    private var profile: BraveProfile!

    override func setUpWithError() throws {
        profileDir = try makeTempDirectory("PasswordReaderTests-profile")
        tempDir = try makeTempDirectory("PasswordReaderTests-temp")
        profile = BraveProfile(directoryName: "Default", displayName: "Personal", url: profileDir)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: profileDir)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func tempContents() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    }

    private func row(_ host: String, _ user: String, _ password: String, created: TimeInterval = 1_700_000_000,
                     lastUsed: TimeInterval = 0, timesUsed: Int = 0) -> LoginDataFixture.Row {
        LoginDataFixture.Row(origin: "https://\(host)/login", action: "https://\(host)/session",
                             realm: "https://\(host)/", username: user, passwordValue: braveEncrypt(password),
                             created: chromiumMicros(created), lastUsed: lastUsed > 0 ? chromiumMicros(lastUsed) : 0,
                             modified: chromiumMicros(created), timesUsed: timesUsed)
    }

    private func neverSave(_ host: String) -> LoginDataFixture.Row {
        LoginDataFixture.Row(origin: "https://\(host)/", realm: "https://\(host)/", username: "",
                             passwordValue: Data(), created: chromiumMicros(1_700_000_000), neverSave: true,
                             usernameElement: "")
    }

    // MARK: - Reading and decrypting

    func testReadsAndDecryptsLoginData() throws {
        let db = try LoginDataFixture(url: profile.loginDataURL)
        try db.insert(row("github.com", "scott", "gh-p@ss wörd 🔑", created: 1_700_000_000,
                          lastUsed: 1_710_000_000, timesUsed: 12))
        try db.insert(row("example.com", "scott@example.com", "x"))
        var basic = row("router.local", "admin", "admin123")
        basic.realm = "http://router.local/Router"
        basic.scheme = 1
        try db.insert(basic)
        db.close()

        let source = TestPasswordSource()
        let result = try BravePasswordReader(passwordSource: source, temporaryDirectory: tempDir).read(profile: profile)

        XCTAssertEqual(source.calls, 1)
        XCTAssertEqual(result.logins.count, 3)
        XCTAssertEqual(result.skippedNeverSave, 0)
        XCTAssertEqual(result.failures, [])

        let github = result.logins[0]
        XCTAssertEqual(github.origin, "https://github.com/login")
        XCTAssertEqual(github.signonRealm, "https://github.com/")
        XCTAssertEqual(github.actionURL, "https://github.com/session")
        XCTAssertEqual(github.username, "scott")
        XCTAssertEqual(github.password, "gh-p@ss wörd 🔑")
        XCTAssertEqual(github.scheme, .html)
        XCTAssertEqual(github.dateCreated, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(github.dateLastUsed, Date(timeIntervalSince1970: 1_710_000_000))
        XCTAssertEqual(github.datePasswordModified, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(github.timesUsed, 12)
        XCTAssertEqual(github.stores, [.profile])

        XCTAssertNil(result.logins[1].dateLastUsed, "0 means never used")
        XCTAssertEqual(result.logins[2].scheme, .basic)
        XCTAssertEqual(result.logins[2].signonRealm, "http://router.local/Router")
        XCTAssertEqual(try tempContents(), [], "temporary copies are wiped")
    }

    func testSkipsNeverSaveRows() throws {
        let db = try LoginDataFixture(url: profile.loginDataURL)
        try db.insert(neverSave("bank.example"))
        try db.insert(row("site.example", "me", "pw"))
        try db.insert(neverSave("ads.example"))
        db.close()

        let result = try BravePasswordReader(passwordSource: TestPasswordSource(), temporaryDirectory: tempDir)
            .read(profile: profile)
        XCTAssertEqual(result.logins.map(\.signonRealm), ["https://site.example/"])
        XCTAssertEqual(result.skippedNeverSave, 2)
    }

    func testOnlyNeverSaveRowsDoNotAskTheKeychain() throws {
        let db = try LoginDataFixture(url: profile.loginDataURL)
        try db.insert(neverSave("bank.example"))
        db.close()
        let source = TestPasswordSource()
        let result = try BravePasswordReader(passwordSource: source, temporaryDirectory: tempDir).read(profile: profile)
        XCTAssertEqual(result.logins, [])
        XCTAssertEqual(result.skippedNeverSave, 1)
        XCTAssertEqual(source.calls, 0, "no encrypted rows, no Keychain prompt")
    }

    func testMergesLoginDataForAccount() throws {
        let local = try LoginDataFixture(url: profile.loginDataURL)
        try local.insert(row("github.com", "scott", "same", created: 1_700_000_000, lastUsed: 1_705_000_000, timesUsed: 3))
        try local.insert(row("local-only.example", "me", "pw1"))
        try local.insert(neverSave("never.example"))
        local.close()
        let account = try LoginDataFixture(url: profile.accountLoginDataURL)
        // The same login saved to the account too, created earlier and used later.
        try account.insert(row("github.com", "scott", "same", created: 1_690_000_000, lastUsed: 1_709_000_000, timesUsed: 7))
        // Same site and user, different password (another form on the site): a different login, kept.
        var changed = row("github.com", "scott", "changed")
        changed.usernameElement = "login"
        try account.insert(changed)
        try account.insert(row("account-only.example", "ünïcode-üser", "pw2"))
        try account.insert(neverSave("never2.example"))
        account.close()

        let source = TestPasswordSource()
        let result = try BravePasswordReader(passwordSource: source, temporaryDirectory: tempDir).read(profile: profile)
        XCTAssertEqual(source.calls, 1, "one Keychain request for both stores")
        XCTAssertEqual(result.logins.map(\.signonRealm),
                       ["https://github.com/", "https://local-only.example/", "https://github.com/",
                        "https://account-only.example/"])
        XCTAssertEqual(result.skippedNeverSave, 2)

        let merged = result.logins[0]
        XCTAssertEqual(merged.stores, [.profile, .account])
        XCTAssertEqual(merged.dateCreated, Date(timeIntervalSince1970: 1_690_000_000))
        XCTAssertEqual(merged.dateLastUsed, Date(timeIntervalSince1970: 1_709_000_000))
        XCTAssertEqual(merged.timesUsed, 7)
        XCTAssertEqual(result.logins[1].stores, [.profile])
        XCTAssertEqual(result.logins[2].password, "changed")
        XCTAssertEqual(result.logins[2].stores, [.account])
        XCTAssertEqual(result.logins[3].username, "ünïcode-üser")
        XCTAssertEqual(result.logins[3].stores, [.account])
    }

    func testAccountStoreAlone() throws {
        let account = try LoginDataFixture(url: profile.accountLoginDataURL)
        try account.insert(row("a.example", "u", "p"))
        account.close()
        let result = try BravePasswordReader(passwordSource: TestPasswordSource(), temporaryDirectory: tempDir)
            .read(profile: profile)
        XCTAssertEqual(result.logins.map(\.stores), [[.account]])
    }

    func testNoLoginDatabases() throws {
        let source = TestPasswordSource()
        let result = try BravePasswordReader(passwordSource: source, temporaryDirectory: tempDir).read(profile: profile)
        XCTAssertEqual(result.logins, [])
        XCTAssertEqual(source.calls, 0)
        XCTAssertEqual(try tempContents(), [])
    }

    // MARK: - Locked files and copies

    /// Brave keeps an exclusive lock on `Login Data` while it runs, often mid-transaction. Opening
    /// the original fails; the reader works from a byte copy, sees only committed rows (the copied
    /// hot journal rolls the copy back), and leaves Brave's files exactly as they were.
    func testReadsWhileBraveHoldsAnExclusiveLock() throws {
        let brave = try LoginDataFixture(url: profile.loginDataURL)
        try brave.insert(row("committed.example", "me", "pw"))
        try brave.exec("PRAGMA locking_mode=EXCLUSIVE")
        try brave.exec("PRAGMA cache_size=1") // spill writes into the file so the journal is hot
        try brave.exec("BEGIN EXCLUSIVE")
        for i in 0..<200 {
            try brave.insert(row("uncommitted-\(i).example", "me", String(repeating: "p", count: 200)))
        }
        defer { try? brave.exec("ROLLBACK"); brave.close() }

        // Prove the lock is real: a direct reader of the original is refused.
        var direct: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(profile.loginDataURL.path, &direct, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        var stmt: OpaquePointer?
        let prepared = sqlite3_prepare_v2(direct, "SELECT count(*) FROM logins", -1, &stmt, nil)
        let stepped = prepared == SQLITE_OK ? sqlite3_step(stmt) : prepared
        sqlite3_finalize(stmt)
        sqlite3_close_v2(direct)
        XCTAssertEqual(stepped, SQLITE_BUSY)
        XCTAssertTrue(FileManager.default.fileExists(atPath: profile.loginDataURL.path + "-journal"))

        let before = try snapshot(profileDir)
        let result = try BravePasswordReader(passwordSource: TestPasswordSource(), temporaryDirectory: tempDir)
            .read(profile: profile)

        XCTAssertEqual(result.logins.map(\.signonRealm), ["https://committed.example/"])
        XCTAssertEqual(try snapshot(profileDir), before, "Brave's files are untouched")
        XCTAssertEqual(try tempContents(), [], "copies are wiped")
    }

    /// With a write-ahead log, recent saves live in `Login Data-wal` until a checkpoint. The copy
    /// takes the log too, so they're imported; no `-shm` or anything else appears beside Brave's files.
    func testIncludesRowsStillInTheWriteAheadLog() throws {
        let brave = try LoginDataFixture(url: profile.loginDataURL, journalMode: "WAL")
        try brave.exec("PRAGMA wal_autocheckpoint=0")
        try brave.insert(row("in-wal.example", "me", "fresh"))
        defer { brave.close() }
        XCTAssertGreaterThan(try XCTUnwrap(FileManager.default.attributesOfItem(
            atPath: profile.loginDataURL.path + "-wal")[.size] as? Int), 0)

        let before = try snapshot(profileDir)
        let result = try BravePasswordReader(passwordSource: TestPasswordSource(), temporaryDirectory: tempDir)
            .read(profile: profile)
        XCTAssertEqual(result.logins.map(\.password), ["fresh"])
        XCTAssertEqual(try snapshot(profileDir), before)
        XCTAssertEqual(try tempContents(), [])
    }

    /// The work folder is owner-only while the reader holds it, and the database copies are deleted
    /// as soon as their rows are read, before any password is decrypted.
    func testWorkFolderIsPrivateAndCopiesGoBeforeDecrypting() throws {
        let db = try LoginDataFixture(url: profile.loginDataURL)
        try db.insert(row("a.example", "u", "p"))
        db.close()
        var modes: [Int] = []
        var filesDuringDecrypt: [String] = []
        let source = TestPasswordSource()
        source.onRequest = {
            let fm = FileManager.default
            for name in (try? fm.contentsOfDirectory(atPath: self.tempDir.path)) ?? [] {
                let attrs = try? fm.attributesOfItem(atPath: self.tempDir.appendingPathComponent(name).path)
                modes.append((attrs?[.posixPermissions] as? NSNumber)?.intValue ?? -1)
                filesDuringDecrypt += (try? fm.subpathsOfDirectory(atPath: self.tempDir.appendingPathComponent(name).path)) ?? []
            }
        }
        _ = try BravePasswordReader(passwordSource: source, temporaryDirectory: tempDir).read(profile: profile)
        XCTAssertEqual(modes, [0o700])
        XCTAssertEqual(filesDuringDecrypt, [])
    }

    func testCopiedFilesAreOwnerOnly() throws {
        let source = tempDir.appendingPathComponent("source")
        try Data("abc".utf8).write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: source.path)
        let copy = tempDir.appendingPathComponent("copy")
        try LoginDatabase.copyFile(source, to: copy)
        let mode = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: copy.path)[.posixPermissions] as? NSNumber)
        XCTAssertEqual(mode.intValue, 0o600)
        XCTAssertEqual(try Data(contentsOf: copy), Data("abc".utf8))
    }

    // MARK: - Failures

    func testWrongSafeStoragePassword() throws {
        let db = try LoginDataFixture(url: profile.loginDataURL)
        try db.insert(row("a.example", "u", "password-one-is-long-enough"))
        try db.insert(row("b.example", "u", "password-two-is-long-enough"))
        db.close()
        let reader = BravePasswordReader(passwordSource: TestPasswordSource("not-the-password"), temporaryDirectory: tempDir)
        XCTAssertThrowsError(try reader.read(profile: profile)) { error in
            XCTAssertEqual(error as? PasswordImportError, .wrongKey)
        }
        XCTAssertEqual(try tempContents(), [])
    }

    func testOneDamagedValueIsReportedNotFatal() throws {
        let db = try LoginDataFixture(url: profile.loginDataURL)
        try db.insert(row("good.example", "u", "fine"))
        var damaged = row("bad.example", "u", "x")
        damaged.passwordValue = Data("v10".utf8) + Data(repeating: 9, count: 17)
        try db.insert(damaged)
        db.close()
        let result = try BravePasswordReader(passwordSource: TestPasswordSource(), temporaryDirectory: tempDir)
            .read(profile: profile)
        XCTAssertEqual(result.logins.map(\.password), ["fine"])
        XCTAssertEqual(result.failures.count, 1)
        XCTAssertEqual(result.failures.first?.origin, "https://bad.example/login")
        XCTAssertEqual(result.failures.first?.reason, .decryptFailed)
    }

    func testKeychainDenialStopsTheImportAndWipesCopies() throws {
        let db = try LoginDataFixture(url: profile.loginDataURL)
        try db.insert(row("a.example", "u", "p"))
        db.close()
        let reader = BravePasswordReader(passwordSource: TestPasswordSource(error: SafeStorageError.denied),
                                         temporaryDirectory: tempDir)
        XCTAssertThrowsError(try reader.read(profile: profile)) { error in
            XCTAssertEqual(error as? SafeStorageError, .denied)
        }
        XCTAssertEqual(try tempContents(), [])
    }

    func testKeyIsAskedForOnceAcrossProfiles() throws {
        let other = try makeTempDirectory("PasswordReaderTests-profile2")
        defer { try? FileManager.default.removeItem(at: other) }
        let second = BraveProfile(directoryName: "Profile 1", displayName: "Work", url: other)
        for p in [profile!, second] {
            let db = try LoginDataFixture(url: p.loginDataURL)
            try db.insert(row("\(p.directoryName.replacingOccurrences(of: " ", with: "")).example", "u", "p"))
            db.close()
        }
        let source = TestPasswordSource()
        let reader = BravePasswordReader(passwordSource: source, temporaryDirectory: tempDir)
        XCTAssertEqual(try reader.read(profile: profile).logins.count, 1)
        XCTAssertEqual(try reader.read(profile: second).logins.count, 1)
        XCTAssertEqual(source.calls, 1)
    }

    func testNotALoginDatabase() throws {
        try Data("SQLite format 3\0 but not really".utf8).write(to: profile.loginDataURL)
        let reader = BravePasswordReader(passwordSource: TestPasswordSource(), temporaryDirectory: tempDir)
        XCTAssertThrowsError(try reader.read(profile: profile))
        XCTAssertEqual(try tempContents(), [])
    }

    func testOlderSchemaWithoutNewerColumns() throws {
        let old = """
            CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR,
              username_value VARCHAR, password_element VARCHAR, password_value BLOB, submit_element VARCHAR,
              signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL,
              scheme INTEGER NOT NULL, password_type INTEGER, times_used INTEGER, date_last_used INTEGER,
              date_password_modified INTEGER);
            """
        let db = try LoginDataFixture(url: profile.loginDataURL, schema: old)
        try db.insert(row("old.example", "u", "p"))
        db.close()
        let result = try BravePasswordReader(passwordSource: TestPasswordSource(), temporaryDirectory: tempDir)
            .read(profile: profile)
        XCTAssertEqual(result.logins.map(\.password), ["p"])
    }
}
