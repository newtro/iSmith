import CryptoKit
import Foundation
import GRDB
import os
import SignInSync

public enum PasswordStoreError: Error, Equatable, CustomStringConvertible {
    /// The Keychain couldn't be read (locked, or access denied). Nothing was changed; try again
    /// once it unlocks.
    case keychainUnavailable(String)
    /// A login with this origin and username already exists.
    case duplicate
    case notFound
    case encryptionFailed
    case unreadableRow
    case invalidOrigin

    public var description: String {
        switch self {
        case .keychainUnavailable(let why): return "The passwords key could not be read from the Keychain (\(why))."
        case .duplicate: return "A login with this username is already saved for this site."
        case .notFound: return "The login no longer exists."
        case .encryptionFailed: return "The login could not be encrypted."
        case .unreadableRow: return "The login could not be decrypted."
        case .invalidOrigin: return "The site address is not an http or https origin."
        }
    }
}

/// iSmith's saved logins: a SQLite database (GRDB) in Application Support, one row per login.
///
/// Each row keeps its origin in the clear, for matching, and its username and password as
/// separate AES-GCM sealed boxes bound to the row (see `LoginCrypto`). The 256-bit key is the
/// same kind as the sign-in vault's, but its own item in the file-based login Keychain
/// (`com.scottsmith.ismith.passwords-key`). Secrets are never logged: errors and log lines carry
/// ids, origins and counts only, and GRDB's statement arguments stay out of its error messages.
///
/// Opening follows the vault's rules. If the Keychain can't be read, `init` throws and nothing is
/// touched. If the database can't be opened with the key (a missing or different key, or a
/// damaged file), the file is moved aside as `passwords.unreadable-<time>.sqlite` and a new one
/// starts; an existing Keychain key is never replaced.
public final class PasswordStore: @unchecked Sendable {
    public static let keychainService = "com.scottsmith.ismith.passwords-key"

    /// The passwords key in the login Keychain, next to (not shared with) the vault key.
    public static func keychainKeyStore() -> KeychainKeyStore {
        KeychainKeyStore(service: keychainService, account: "passwords", label: "iSmith passwords key")
    }

    /// `~/Library/Application Support/iSmith/passwords.sqlite`, or under `dataDirectory`.
    public static func defaultFileURL(dataDirectory: URL? = nil) -> URL {
        let dir = dataDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("iSmith", isDirectory: true)
        return dir.appendingPathComponent("passwords.sqlite")
    }

    public let fileURL: URL
    /// Where an unreadable database was moved when this store opened, if it was.
    public let movedAside: URL?
    private let dbQueue: DatabaseQueue
    private let key: SymmetricKey
    private static let log = Logger(subsystem: "com.scottsmith.ismith", category: "passwords")

    public init(fileURL: URL, keyStore: KeyStore) throws {
        self.fileURL = fileURL
        try SecureFile.prepareDirectory(fileURL.deletingLastPathComponent())

        var key: SymmetricKey?
        do {
            key = try keyStore.loadKey()
        } catch {
            Self.log.error("passwords key unreadable; store not opened")
            throw PasswordStoreError.keychainUnavailable(String(describing: error))
        }

        var movedAside: URL?
        if FileManager.default.fileExists(atPath: fileURL.path), !Self.isUsable(fileURL, key: key) {
            movedAside = try SecureFile.moveAside(fileURL, reason: "unreadable")
            Self.log.error("passwords database could not be opened with the Keychain key; moved aside")
        }

        if key == nil {
            let fresh = SymmetricKey(size: .bits256)
            do {
                try keyStore.saveKey(fresh)
                key = fresh
            } catch {
                // Another launch may have saved one first: use it rather than replace it.
                if let saved = try? keyStore.loadKey() {
                    key = saved
                } else {
                    throw PasswordStoreError.keychainUnavailable(String(describing: error))
                }
            }
        }
        guard let key else { throw PasswordStoreError.keychainUnavailable("no key") }
        self.key = key
        self.movedAside = movedAside

        try SecureFile.ensureOwnerOnlyFile(fileURL)
        dbQueue = try DatabaseQueue(path: fileURL.path, configuration: Self.configuration())
        try Self.migrator.migrate(dbQueue)
        try dbQueue.write { db in
            if try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'keyCheck'") == nil {
                try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('keyCheck', ?)",
                               arguments: [LoginCrypto.sealKeyCheck(key)])
            }
        }
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.label = "iSmith.passwords"
        // Deleted rows are overwritten with zeros rather than left in free pages.
        // The file is untrusted input: schema objects (triggers, views) may not call functions
        // with side effects.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
        }
        return config
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE meta (key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);
                CREATE TABLE login (
                    id TEXT PRIMARY KEY NOT NULL,
                    origin TEXT NOT NULL,
                    username BLOB NOT NULL,
                    password BLOB NOT NULL,
                    created DOUBLE NOT NULL,
                    updated DOUBLE NOT NULL,
                    lastUsed DOUBLE,
                    timesUsed INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX login_origin ON login(origin);
                CREATE TABLE neverSave (origin TEXT PRIMARY KEY NOT NULL, created DOUBLE NOT NULL);
                """)
        }
        return migrator
    }

    /// Whether an existing database file opens with this key: its key check verifies, or it has
    /// no key check and no logins yet. A missing key can open only an empty database.
    private static func isUsable(_ url: URL, key: SymmetricKey?) -> Bool {
        do {
            let queue = try DatabaseQueue(path: url.path, configuration: configuration())
            defer { try? queue.close() }
            return try queue.read { db in
                guard try db.tableExists("meta"), try db.tableExists("login") else {
                    // Created but never migrated (or not ours): usable only if it holds nothing.
                    return try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
                        .allSatisfy { $0.hasPrefix("sqlite_") || $0 == "grdb_migrations" }
                }
                if let check = try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'keyCheck'") {
                    guard let key else { return false }
                    return LoginCrypto.verifyKeyCheck(check, key: key)
                }
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM login") == 0
            }
        } catch {
            return false
        }
    }

    // MARK: Reading

    /// Every readable login, by site and then username. Rows that fail to decrypt are skipped and
    /// counted by `unreadableCount()`.
    public func allLogins() throws -> [Login] {
        try dbQueue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM login").compactMap(decode) }
            .sorted(by: Self.listOrder)
    }

    public func login(id: UUID) throws -> Login? {
        try dbQueue.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM login WHERE id = ?", arguments: [id.uuidString]).flatMap(decode)
        }
    }

    /// Rows that exist but can't be decrypted with the current key (tampered or damaged).
    public func unreadableCount() throws -> Int {
        try dbQueue.read { db in try Row.fetchAll(db, sql: "SELECT * FROM login").filter { decode($0) == nil }.count }
    }

    /// Logins that may be offered on a frame of `origin`: exact matches first, then same-site
    /// ones, each most recently used first. See `Origin` for the rules.
    public func logins(for origin: Origin) throws -> [LoginMatch] {
        try dbQueue.read { db -> [LoginMatch] in
            // Origins are in the clear, so only matching rows are decrypted.
            try Row.fetchAll(db, sql: "SELECT * FROM login").compactMap { row -> LoginMatch? in
                guard let saved = Origin(string: row["origin"]),
                      let kind = Origin.match(saved: saved, page: origin),
                      let login = decode(row) else { return nil }
                return LoginMatch(login: login, kind: kind)
            }
        }
        .sorted { a, b in
            if a.kind != b.kind { return a.kind < b.kind }
            if a.login.lastUsed != b.login.lastUsed { return (a.login.lastUsed ?? .distantPast) > (b.login.lastUsed ?? .distantPast) }
            return Self.listOrder(a.login, b.login)
        }
    }

    /// Logins whose host or username contains `query` (case- and diacritic-insensitive). An empty
    /// query returns every login. Passwords are never searched.
    public func search(_ query: String) throws -> [Login] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let all = try allLogins()
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.origin.host.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.username.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    // MARK: Writing

    /// Adds a login. Throws `.duplicate` if the origin already has this username.
    @discardableResult
    public func add(origin: Origin, username: String, password: String, date: Date = Date()) throws -> Login {
        let login = Login(origin: origin, username: username, password: password, created: date)
        try dbQueue.write { db in
            guard try existing(db, origin: origin, username: username) == nil else { throw PasswordStoreError.duplicate }
            try insert(db, login)
        }
        return login
    }

    /// Saves a login's origin, username and password (and dates). Changing the password moves
    /// `updated` to now. Throws `.duplicate` if the new origin and username belong to another login.
    @discardableResult
    public func update(_ login: Login, date: Date = Date()) throws -> Login {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(db, sql: "SELECT * FROM login WHERE id = ?", arguments: [login.id.uuidString]) else {
                throw PasswordStoreError.notFound
            }
            if let other = try existing(db, origin: login.origin, username: login.username), other.id != login.id {
                throw PasswordStoreError.duplicate
            }
            var saved = login
            if let old = decode(row), old.password == login.password {
                saved.updated = old.updated
            } else {
                saved.updated = date
            }
            try db.execute(sql: "DELETE FROM login WHERE id = ?", arguments: [login.id.uuidString])
            try insert(db, saved)
            return saved
        }
    }

    /// Saves a captured sign-in: updates the password of the origin's login with this username,
    /// or adds a new login.
    @discardableResult
    public func save(origin: Origin, username: String, password: String, date: Date = Date()) throws -> Login {
        try dbQueue.write { db in
            if var login = try existing(db, origin: origin, username: username) {
                if login.password != password {
                    login.password = password
                    login.updated = date
                }
                login.lastUsed = date
                login.timesUsed += 1
                try db.execute(sql: "DELETE FROM login WHERE id = ?", arguments: [login.id.uuidString])
                try insert(db, login)
                return login
            }
            var login = Login(origin: origin, username: username, password: password, created: date)
            login.lastUsed = date
            login.timesUsed = 1
            try insert(db, login)
            return login
        }
    }

    public func delete(id: UUID) throws {
        try dbQueue.write { db in try db.execute(sql: "DELETE FROM login WHERE id = ?", arguments: [id.uuidString]) }
    }

    /// Records that a login was filled or signed in with.
    public func markUsed(id: UUID, date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "UPDATE login SET lastUsed = ?, timesUsed = timesUsed + 1 WHERE id = ?",
                           arguments: [date.timeIntervalSince1970, id.uuidString])
        }
    }

    /// What a submitted sign-in on `origin` should lead to:
    /// - `.neverSave` when the origin is on the "never save" list;
    /// - `.unchanged` when this origin already has the username with this password, or a
    ///   same-site login has both (the user signed in with a login offered from a sibling host);
    /// - `.update` when this origin has the username with another password;
    /// - `.save` otherwise (a same-site login with another password is left alone, and a new
    ///   login is saved for this exact origin).
    public func proposal(for origin: Origin, username: String, password: String) throws -> SaveAction {
        if try isNeverSave(origin) { return .neverSave }
        let matches = try logins(for: origin).filter { $0.login.username == username }
        if let exact = matches.first(where: { $0.kind == .exact }) {
            return exact.login.password == password ? .unchanged(existing: exact.login.id) : .update(existing: exact.login.id)
        }
        if let sibling = matches.first(where: { $0.login.password == password }) {
            return .unchanged(existing: sibling.login.id)
        }
        return .save
    }

    // MARK: Never save

    public func setNeverSave(_ origin: Origin, date: Date = Date()) throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO neverSave (origin, created) VALUES (?, ?)",
                           arguments: [origin.serialized, date.timeIntervalSince1970])
        }
    }

    public func removeNeverSave(_ origin: Origin) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM neverSave WHERE origin = ?", arguments: [origin.serialized])
        }
    }

    /// "Never save" is per exact origin.
    public func isNeverSave(_ origin: Origin) throws -> Bool {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM neverSave WHERE origin = ?", arguments: [origin.serialized]) ?? 0 > 0
        }
    }

    public func neverSaveOrigins() throws -> [Origin] {
        try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT origin FROM neverSave ORDER BY origin").compactMap { Origin(string: $0) }
        }
    }

    // MARK: Password health

    /// Weak passwords and passwords reused across sites, for the manager window.
    public func securityReport() throws -> SecurityReport {
        SecurityReport(logins: try allLogins())
    }

    // MARK: Rows

    private func existing(_ db: Database, origin: Origin, username: String) throws -> Login? {
        try Row.fetchAll(db, sql: "SELECT * FROM login WHERE origin = ?", arguments: [origin.serialized])
            .compactMap(decode)
            .first { $0.username == username }
    }

    private func insert(_ db: Database, _ login: Login) throws {
        try db.execute(sql: """
            INSERT INTO login (id, origin, username, password, created, updated, lastUsed, timesUsed)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [
                login.id.uuidString,
                login.origin.serialized,
                LoginCrypto.seal(login.username, id: login.id, origin: login.origin, field: .username, key: key),
                LoginCrypto.seal(login.password, id: login.id, origin: login.origin, field: .password, key: key),
                login.created.timeIntervalSince1970,
                login.updated.timeIntervalSince1970,
                login.lastUsed?.timeIntervalSince1970,
                login.timesUsed,
            ])
    }

    private func decode(_ row: Row) -> Login? {
        guard let idText: String = row["id"], let id = UUID(uuidString: idText),
              let originText: String = row["origin"], let origin = Origin(string: originText),
              let userBox: Data = row["username"], let passBox: Data = row["password"],
              let username = try? LoginCrypto.open(userBox, id: id, origin: origin, field: .username, key: key),
              let password = try? LoginCrypto.open(passBox, id: id, origin: origin, field: .password, key: key)
        else { return nil }
        let lastUsed: Double? = row["lastUsed"]
        return Login(id: id, origin: origin, username: username, password: password,
                     created: Date(timeIntervalSince1970: row["created"]),
                     updated: Date(timeIntervalSince1970: row["updated"]),
                     lastUsed: lastUsed.map(Date.init(timeIntervalSince1970:)),
                     timesUsed: row["timesUsed"])
    }

    private static func listOrder(_ a: Login, _ b: Login) -> Bool {
        let sa = a.origin.site ?? a.origin.host, sb = b.origin.site ?? b.origin.host
        if sa != sb { return sa < sb }
        if a.origin != b.origin { return a.origin < b.origin }
        return a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending
    }
}
