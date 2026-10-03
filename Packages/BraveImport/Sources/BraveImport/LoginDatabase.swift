import Foundation
import SQLite3

/// One row of Chromium's `logins` table, before decryption.
struct RawLogin {
    var originURL: String
    var actionURL: String
    var signonRealm: String
    var username: String
    var passwordValue: Data
    var dateCreated: Int64
    var dateLastUsed: Int64
    var datePasswordModified: Int64
    var neverSave: Bool
    var timesUsed: Int
    var scheme: Int
}

public enum LoginDatabaseError: Error, Equatable {
    /// SQLite couldn't open or read the copy, with SQLite's message.
    case sqlite(Int32, String)
    /// The file has no `logins` table, or it lacks a column every Chromium version has.
    case notALoginDatabase(String)
    /// The copy kept failing to read: Brave was probably writing the file while it was copied.
    case copyInconsistent(String)
}

/// Reads Chromium login databases from private copies, never from Brave's own files.
///
/// Brave keeps `Login Data` open (and locked) while it runs, so the file and any journal or
/// write-ahead log beside it are byte-copied into a private folder and the copy is opened instead.
/// A copy taken mid-write can be torn; reading is retried on a fresh copy a few times.
enum LoginDatabase {
    /// Companion files SQLite needs to see the latest committed data. `-shm` is not copied: it is
    /// only an index of the `-wal`, and SQLite rebuilds it.
    static let companionSuffixes = ["-journal", "-wal"]
    static let attempts = 3

    static func readRows(copyOf source: URL, workDirectory: URL) throws -> [RawLogin] {
        var lastError: Error = LoginDatabaseError.copyInconsistent(source.lastPathComponent)
        for attempt in 1...attempts {
            let copyDir = workDirectory.appendingPathComponent("copy-\(attempt)-\(UUID().uuidString)", isDirectory: true)
            try makePrivateDirectory(copyDir)
            defer { try? FileManager.default.removeItem(at: copyDir) }
            let copy = copyDir.appendingPathComponent("Login Data")
            try copyFile(source, to: copy)
            for suffix in companionSuffixes {
                let companion = URL(fileURLWithPath: source.path + suffix)
                if FileManager.default.fileExists(atPath: companion.path) {
                    // A companion can vanish between the check and the copy (a checkpoint); that's fine.
                    try? copyFile(companion, to: URL(fileURLWithPath: copy.path + suffix))
                }
            }
            do {
                return try readRows(openingCopy: copy)
            } catch LoginDatabaseError.sqlite(let code, let message)
                        where code == SQLITE_CORRUPT || code == SQLITE_NOTADB || code == SQLITE_IOERR {
                lastError = LoginDatabaseError.copyInconsistent("\(source.lastPathComponent): \(message)")
                continue
            }
        }
        throw lastError
    }

    /// Reads the rows of a database file that belongs to this process (a private copy).
    static func readRows(openingCopy path: URL) throws -> [RawLogin] {
        var db: OpaquePointer?
        // Read-write so SQLite can apply a copied hot journal or WAL to the copy itself.
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path.path, &db, flags, nil)
        defer { sqlite3_close_v2(db) }
        guard rc == SQLITE_OK, let db else { throw error(db, rc) }

        let columns = try tableColumns(db, "logins")
        guard !columns.isEmpty else { throw LoginDatabaseError.notALoginDatabase("no logins table") }
        let required = ["origin_url", "username_value", "password_value", "signon_realm", "blacklisted_by_user"]
        for name in required where !columns.contains(name) {
            throw LoginDatabaseError.notALoginDatabase("logins has no \(name) column")
        }
        // Columns added in later Chromium versions read as their defaults when absent.
        let wanted = ["origin_url", "action_url", "signon_realm", "username_value", "password_value",
                      "date_created", "date_last_used", "date_password_modified", "blacklisted_by_user",
                      "times_used", "scheme"]
        let select = wanted.map { columns.contains($0) ? "\"\($0)\"" : "NULL" }.joined(separator: ", ")
        let order = columns.contains("id") ? " ORDER BY id" : ""
        let stmt = try prepare(db, "SELECT \(select) FROM logins\(order)")
        defer { sqlite3_finalize(stmt) }

        var rows: [RawLogin] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error(db, step) }
            rows.append(RawLogin(originURL: text(stmt, 0), actionURL: text(stmt, 1), signonRealm: text(stmt, 2),
                                 username: text(stmt, 3), passwordValue: blob(stmt, 4),
                                 dateCreated: sqlite3_column_int64(stmt, 5),
                                 dateLastUsed: sqlite3_column_int64(stmt, 6),
                                 datePasswordModified: sqlite3_column_int64(stmt, 7),
                                 neverSave: sqlite3_column_int64(stmt, 8) != 0,
                                 timesUsed: Int(sqlite3_column_int64(stmt, 9)),
                                 scheme: Int(sqlite3_column_int64(stmt, 10))))
        }
        return rows
    }

    // MARK: - Files

    static func makePrivateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    /// A plain read of the source (opened read-only, so the original can't be changed) written to
    /// a new owner-only file.
    static func copyFile(_ source: URL, to destination: URL) throws {
        let data = try BraveFiles.read(source)
        guard FileManager.default.createFile(atPath: destination.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
        }
    }

    // MARK: - SQLite helpers

    private static func tableColumns(_ db: OpaquePointer, _ table: String) throws -> Set<String> {
        let stmt = try prepare(db, "PRAGMA table_info(\"\(table)\")")
        defer { sqlite3_finalize(stmt) }
        var names = Set<String>()
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { throw error(db, step) }
            names.insert(text(stmt, 1))
        }
        return names
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw error(db, rc) }
        return stmt
    }

    private static func text(_ stmt: OpaquePointer, _ index: Int32) -> String {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return "" }
        let count = Int(sqlite3_column_bytes(stmt, index))
        return String(decoding: Data(bytes: bytes, count: count), as: UTF8.self)
    }

    private static func blob(_ stmt: OpaquePointer, _ index: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(stmt, index)))
    }

    private static func error(_ db: OpaquePointer?, _ code: Int32) -> LoginDatabaseError {
        let message = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? String(cString: sqlite3_errstr(code))
        return .sqlite(code & 0xFF, message)
    }
}
