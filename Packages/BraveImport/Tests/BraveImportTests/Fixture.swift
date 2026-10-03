import BraveImport
import CommonCrypto
import Foundation
import SQLite3
import XCTest

/// A per-test folder, deleted afterwards.
func makeTempDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A fixed "Brave Safe Storage" password. Never the real Keychain.
final class TestPasswordSource: SafeStoragePasswordSource {
    var password: Data
    var error: Error?
    private(set) var calls = 0
    /// Runs on each request, while the reader holds its copies (to observe the temp folder).
    var onRequest: (() -> Void)?

    init(_ password: String = "test-safe-storage-password", error: Error? = nil) {
        self.password = Data(password.utf8)
        self.error = error
    }

    func safeStoragePassword() throws -> Data {
        calls += 1
        onRequest?()
        if let error { throw error }
        return password
    }
}

/// Chromium time (µs since 1601) for a Unix time in seconds.
func chromiumMicros(_ unix: TimeInterval) -> Int64 {
    Int64(unix * 1_000_000) + 11_644_473_600 * 1_000_000
}

/// Builds a `Login Data` file with Chromium's real `logins` schema, written by the C API.
final class LoginDataFixture {
    let url: URL
    private(set) var db: OpaquePointer?

    struct Row {
        var origin: String
        var action: String = ""
        var realm: String
        var username: String
        var passwordValue: Data
        var created: Int64 = 0
        var lastUsed: Int64 = 0
        var modified: Int64 = 0
        var neverSave = false
        var timesUsed = 0
        var scheme = 0
        var usernameElement = "username"
    }

    /// Chromium's schema for `logins` (current versions, where `times_used` became
    /// `times_used_in_html_form`), its `password_notes` table and its `meta` table.
    static let schema = """
        CREATE TABLE meta(key LONGVARCHAR NOT NULL UNIQUE PRIMARY KEY, value LONGVARCHAR);
        INSERT INTO meta VALUES('version', '43'), ('last_compatible_version', '40');
        CREATE TABLE logins (origin_url VARCHAR NOT NULL, action_url VARCHAR, username_element VARCHAR,
          username_value VARCHAR, password_element VARCHAR, password_value BLOB, submit_element VARCHAR,
          signon_realm VARCHAR NOT NULL, date_created INTEGER NOT NULL, blacklisted_by_user INTEGER NOT NULL,
          scheme INTEGER NOT NULL, password_type INTEGER, times_used_in_html_form INTEGER, form_data BLOB,
          display_name VARCHAR, icon_url VARCHAR, federation_url VARCHAR, skip_zero_click INTEGER,
          generation_upload_status INTEGER, possible_username_pairs BLOB,
          id INTEGER PRIMARY KEY AUTOINCREMENT, date_last_used INTEGER NOT NULL DEFAULT 0,
          moving_blocked_for BLOB, date_password_modified INTEGER NOT NULL DEFAULT 0,
          sender_email VARCHAR, sender_name VARCHAR, date_received INTEGER,
          sharing_notification_displayed INTEGER NOT NULL DEFAULT 0, keychain_identifier BLOB,
          sender_profile_image_url VARCHAR,
          UNIQUE (origin_url, username_element, username_value, password_element, signon_realm));
        CREATE INDEX logins_signon ON logins (signon_realm);
        CREATE TABLE password_notes (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
          parent_id INTEGER NOT NULL REFERENCES logins ON UPDATE CASCADE ON DELETE CASCADE
            DEFERRABLE INITIALLY DEFERRED,
          key VARCHAR NOT NULL, value BLOB, date_created INTEGER, confidential INTEGER,
          UNIQUE (parent_id, key));
        """

    private let timesUsedColumn: String

    init(url: URL, journalMode: String = "DELETE", schema: String = LoginDataFixture.schema) throws {
        self.url = url
        timesUsedColumn = schema.contains("times_used_in_html_form") ? "times_used_in_html_form" : "times_used"
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw fail("open") }
        try exec("PRAGMA journal_mode=\(journalMode)")
        try exec(schema)
    }

    deinit { close() }

    func close() {
        if let db { sqlite3_close_v2(db) }
        db = nil
    }

    func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "?"
            sqlite3_free(message)
            throw NSError(domain: "fixture", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(sql): \(text)"])
        }
    }

    /// Inserts a login and returns its `id`.
    @discardableResult
    func insert(_ row: Row) throws -> Int64 {
        let sql = """
            INSERT INTO logins (origin_url, action_url, username_element, username_value, password_element,
              password_value, submit_element, signon_realm, date_created, blacklisted_by_user, scheme,
              password_type, \(timesUsedColumn), date_last_used, date_password_modified)
            VALUES (?, ?, ?, ?, 'password', ?, '', ?, ?, ?, ?, 0, ?, ?, ?)
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw fail("prepare") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, row.origin, -1, transient)
        sqlite3_bind_text(stmt, 2, row.action, -1, transient)
        sqlite3_bind_text(stmt, 3, row.usernameElement, -1, transient)
        sqlite3_bind_text(stmt, 4, row.username, -1, transient)
        _ = row.passwordValue.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 5, bytes.baseAddress, Int32(row.passwordValue.count), transient)
        }
        sqlite3_bind_text(stmt, 6, row.realm, -1, transient)
        sqlite3_bind_int64(stmt, 7, row.created)
        sqlite3_bind_int(stmt, 8, row.neverSave ? 1 : 0)
        sqlite3_bind_int(stmt, 9, Int32(row.scheme))
        sqlite3_bind_int(stmt, 10, Int32(row.timesUsed))
        sqlite3_bind_int64(stmt, 11, row.lastUsed)
        sqlite3_bind_int64(stmt, 12, row.modified)
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw fail("insert") }
        return sqlite3_last_insert_rowid(db)
    }

    func addNote(to login: Int64, key: String = "", value: Data) throws {
        var stmt: OpaquePointer?
        let sql = "INSERT INTO password_notes (parent_id, key, value, date_created, confidential) VALUES (?, ?, ?, 0, 0)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw fail("prepare note") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_int64(stmt, 1, login)
        sqlite3_bind_text(stmt, 2, key, -1, transient)
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(stmt, 3, bytes.baseAddress, Int32(value.count), transient)
        }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw fail("insert note") }
    }

    private func fail(_ what: String) -> NSError {
        NSError(domain: "fixture", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "\(what): \(db.map { String(cString: sqlite3_errmsg($0)) } ?? "?")"])
    }
}

/// The bytes of a file and every SQLite companion beside it, to prove nothing was changed.
func snapshot(_ dir: URL) throws -> [String: Data] {
    var result: [String: Data] = [:]
    for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
        result[name] = try Data(contentsOf: dir.appendingPathComponent(name))
    }
    return result
}

/// Encrypts a password the way Brave does on macOS, written independently of the package's
/// cipher: PBKDF2-HMAC-SHA1(password, "saltysalt", 1003, 16 bytes), AES-128-CBC with PKCS7 and an
/// IV of 16 spaces, prefixed with "v10".
func braveEncrypt(_ text: String, safeStoragePassword: String = "test-safe-storage-password") -> Data {
    let password = Array(safeStoragePassword.utf8)
    let salt = Array("saltysalt".utf8)
    var key = [UInt8](repeating: 0, count: 16)
    let derive = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), safeStoragePassword, password.count,
                                      salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                      &key, key.count)
    precondition(derive == kCCSuccess)
    let iv = [UInt8](repeating: 0x20, count: 16)
    let input = Array(text.utf8)
    var output = [UInt8](repeating: 0, count: input.count + 16)
    var moved = 0
    let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                         key, key.count, iv, input, input.count, &output, output.count, &moved)
    precondition(status == kCCSuccess)
    return Data("v10".utf8) + Data(output.prefix(moved))
}
