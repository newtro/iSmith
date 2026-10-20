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
    /// The database file exists but couldn't be read just now (locked by another process, a
    /// permissions or disk error). Nothing was changed; try again.
    case databaseUnavailable(String)
    /// The Keychain has no passwords key, but the file holds logins (or a key check) sealed with
    /// one. Nothing was created, moved or changed. The app offers "Start a New Passwords File…"
    /// (`OpenMode.appStartOver`); any other process just reports it.
    case keyMissing
    /// `existingOnly`: there's no passwords file. Nothing was created.
    case fileMissing
    /// `existingOnly`: the file holds logins sealed with another key. Nothing was moved.
    case wrongKey
    /// `existingOnly`: the file isn't a passwords database (or is damaged). Nothing was moved.
    case unrecognizedFile
    /// `existingOnly`: the file isn't fully set up yet (an older format, migrations still to run,
    /// or no key check). Only the iSmith app sets a file up; open iSmith once.
    case notSetUp
    /// The call is for the iSmith app only (restoring copies set aside), and this store was
    /// opened `existingOnly`.
    case appOnly
    /// Moving an unreadable file aside failed part way and couldn't be fully undone. Says where
    /// each file is now (paths only). Nothing was deleted.
    case moveAsideIncomplete(String)
    /// The database file is missing but SQLite files that belong to it (`-wal`, `-shm`,
    /// `-journal`) are still there, as a move or a delete interrupted part way leaves them. The
    /// `-wal` may hold committed logins, and a new database at this path would discard it, so
    /// nothing is created; they're kept where they are (the paths are listed).
    case orphanedSideFiles([String])

    public var description: String {
        switch self {
        case .orphanedSideFiles(let paths): return "The saved passwords file is missing, but files that belong to it are still there: \(paths.joined(separator: ", "))."
        case .moveAsideIncomplete(let where_): return "The saved passwords file couldn't be moved aside completely: \(where_)"
        case .keyMissing: return "The passwords key isn't in the Keychain, but there is a saved passwords file that holds (or may hold) logins sealed with it."
        case .fileMissing: return "There is no saved passwords file."
        case .wrongKey: return "The saved passwords file doesn't open with the key in the Keychain."
        case .unrecognizedFile: return "The saved passwords file isn't one iSmith can read."
        case .notSetUp: return "The saved passwords file hasn't been set up by iSmith yet."
        case .appOnly: return "Only the iSmith app can do this."
        case .keychainUnavailable(let why): return "The passwords key could not be read from the Keychain (\(why))."
        case .duplicate: return "A login with this username is already saved for this site."
        case .notFound: return "The login no longer exists."
        case .encryptionFailed: return "The login could not be encrypted."
        case .unreadableRow: return "The login could not be decrypted."
        case .invalidOrigin: return "The site address is not an http or https origin."
        case .databaseUnavailable(let why): return "The saved passwords file could not be read (\(why))."
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
/// Opening depends on who opens it (`OpenMode`): only the iSmith app ever creates a key or a
/// file, or moves a file aside, and it never creates a key over a file that holds logins. If the
/// Keychain can't be read, `init` throws and nothing is touched.
///
/// The file is in WAL mode with a busy timeout, so the app and another process (the iSmith
/// Agent) can have it open at once: readers never wait, and writers wait their turn.
public final class PasswordStore: @unchecked Sendable {
    /// Who is opening the store, which decides what `init` may change on disk.
    public enum OpenMode: Equatable, Sendable {
        /// The iSmith app. On a true first run (no file, or a file that holds nothing) it creates
        /// the key and the file. A missing key over a file that holds logins (or a key check)
        /// throws `keyMissing`: a key is never created over existing data. A key that is there
        /// but doesn't open the file (a different key, or a damaged file) moves the file aside
        /// as `passwords.unreadable-<time>.sqlite` and starts a new one; `recover(from:)` adds
        /// its logins back if the key that sealed them returns. Converts an older file to WAL
        /// and runs migrations.
        case app
        /// Any process other than the iSmith app. Never creates a key or a file, never moves,
        /// deletes, migrates or converts one, and never restores or backs up. A missing key
        /// (`keyMissing`), a missing file (`fileMissing`), a file sealed with another key
        /// (`wrongKey`), a file that isn't ours (`unrecognizedFile`) or one the app hasn't set
        /// up yet (`notSetUp`) is an error, and everything is left as it was.
        case existingOnly
        /// The app, after the user chose "Start a New Passwords File…" because the key is
        /// really gone. Like `app`, except that a missing key over a file that holds logins
        /// creates a new key and moves the old file aside (never deletes it). Only ever from an
        /// explicit user choice.
        case appStartOver

        /// `app` or `appStartOver`.
        public var isApp: Bool { self != .existingOnly }
    }

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

    /// How long a write waits for another connection (or process) to finish its own.
    public static let busyTimeout: TimeInterval = 5

    public let fileURL: URL
    public let openMode: OpenMode
    /// Where an unreadable database was moved when this store opened, if it was (app modes only).
    public let movedAside: URL?
    /// A `DatabasePool` in the app; a `DatabaseQueue` in `existingOnly`, which (unlike a pool)
    /// opens a WAL file without writing to it.
    let database: any DatabaseWriter
    private let key: SymmetricKey
    private static let log = Logger(subsystem: "com.scottsmith.ismith", category: "passwords")

    /// Tests only: called at named points of `init` and `recover` to stage races.
    nonisolated(unsafe) static var testHook: ((String) -> Void)?

    /// The store's hold on `<file>.lock` for as long as it's open (see `StoreLock`).
    private let lock: StoreLock

    public init(fileURL: URL, keyStore: KeyStore, mode: OpenMode) throws {
        self.fileURL = fileURL
        self.openMode = mode

        var key: SymmetricKey?
        do {
            key = try keyStore.loadKey()
        } catch {
            Self.log.error("passwords key unreadable; store not opened")
            throw PasswordStoreError.keychainUnavailable(String(describing: error))
        }

        if mode == .existingOnly {
            // Judged without changing anything: no key, no file or a file that doesn't open
            // with the key is an error. Nothing below creates, moves, converts or checkpoints a
            // file (the -shm index aside, which every reader updates).
            guard let key else { throw PasswordStoreError.keyMissing }
            try Self.refuseOrphanedSideFiles(fileURL)
            guard FileManager.default.fileExists(atPath: fileURL.path) else { throw PasswordStoreError.fileMissing }
            switch Self.format(of: fileURL) {
            case .notSQLite: throw PasswordStoreError.unrecognizedFile
            // An older (rollback-journal) or empty file is set up by the app, not here.
            case .empty, .rollbackJournal: throw PasswordStoreError.notSetUp
            case .wal: break
            }
            // A read-only connection never checkpoints or deletes the WAL, but needs the side
            // files to exist; the app leaves them in place (SQLite on macOS keeps them).
            guard SecureFile.sideFiles(of: fileURL).dropFirst().allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
                throw PasswordStoreError.notSetUp
            }
            // Held while open, so the app can't move the file aside under us. The app makes the
            // lock file; without one, the app hasn't opened this file yet.
            let lock = try StoreLock(for: fileURL, create: false)
            let inode = SecureFile.inode(of: fileURL)
            guard inode != nil else { throw PasswordStoreError.fileMissing }
            switch Self.inspect(fileURL, key: key, readOnly: true) {
            case .usable: break
            case .wrongKey: throw PasswordStoreError.wrongKey
            case .notOurs: throw PasswordStoreError.unrecognizedFile
            case .unavailable(let why): throw PasswordStoreError.databaseUnavailable(why)
            }
            Self.testHook?("existingOnly.inspected")
            // A queue, not a pool: a pool's setup writes to the file when its WAL is empty.
            let queue: DatabaseQueue
            do {
                queue = try DatabaseQueue(path: fileURL.path, configuration: Self.configuration())
            } catch let error as DatabaseError {
                throw PasswordStoreError.databaseUnavailable("SQLite error \(error.resultCode.rawValue)")
            }
            // The connection kept is the one checked: same file, set up, and sealed with this key.
            do {
                guard SecureFile.inode(of: fileURL) == inode else {
                    throw PasswordStoreError.databaseUnavailable("the passwords file changed while it was being opened")
                }
                try queue.read { db in
                    guard try Self.migrator.hasCompletedMigrations(db),
                          let check = try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'keyCheck'")
                    else { throw PasswordStoreError.notSetUp }
                    guard LoginCrypto.verifyKeyCheck(check, key: key) else { throw PasswordStoreError.wrongKey }
                }
            } catch {
                try? queue.close()
                throw (error as? DatabaseError).map { PasswordStoreError.databaseUnavailable("SQLite error \($0.resultCode.rawValue)") } ?? error
            }
            self.key = key
            self.movedAside = nil
            self.database = queue
            self.lock = lock
            return
        }

        try SecureFile.prepareDirectory(fileURL.deletingLastPathComponent())
        // Every open store holds the lock shared; moving the file aside needs it alone.
        let lock = try StoreLock(for: fileURL, create: true)
        // A missing file is a first run only if nothing of it is left: a -wal without its
        // database may hold committed logins that a new database would discard.
        try Self.refuseOrphanedSideFiles(fileURL)
        let exists = FileManager.default.fileExists(atPath: fileURL.path)

        // What's on disk is judged before anything changes. A file that can't be read right now
        // (locked, a disk or permissions error) is left alone: only a file that is definitely not
        // a passwords database, or is sealed with another key, is ever moved aside.
        if exists, case .unavailable(let why) = Self.inspect(fileURL, key: key) {
            Self.log.error("passwords database could not be read; nothing changed")
            throw PasswordStoreError.databaseUnavailable(why)
        }

        if key == nil {
            // A key is created only on a true first run: no file, or a file that holds nothing.
            // A file with logins (or a key check) without a key is a Keychain problem to report,
            // not a reason to start over, unless the user chose to (`appStartOver`). A file that
            // can't be judged (damaged) counts as holding logins.
            if exists, Self.inspect(fileURL, key: nil) != .usable, mode != .appStartOver {
                Self.log.error("passwords key missing but the database holds logins; nothing changed")
                throw PasswordStoreError.keyMissing
            }
            // Saved before any file is moved, so a Keychain that refuses the new key leaves
            // everything as it was.
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

        var movedAside: URL?
        var exclusive = false
        if exists {
            var judged = Self.inspect(fileURL, key: key)
            if judged == .wrongKey || judged == .notOurs {
                // Only with the file to ourselves: no other store (another launch, the Agent)
                // has it open. Then judged again, since another launch may have replaced it
                // since our first look.
                guard lock.lockExclusively(between: { Self.testHook?("app.beforeExclusive") }) else {
                    Self.log.error("passwords database needs moving aside but another process has it open; nothing changed")
                    throw PasswordStoreError.databaseUnavailable("another process has the passwords file open")
                }
                exclusive = true
                try Self.refuseOrphanedSideFiles(fileURL)
                judged = FileManager.default.fileExists(atPath: fileURL.path) ? Self.inspect(fileURL, key: key) : .usable
            }
            switch judged {
            case .usable:
                break
            case .unavailable(let why):
                throw PasswordStoreError.databaseUnavailable(why)
            case .wrongKey, .notOurs:
                do {
                    movedAside = try SecureFile.moveAside(fileURL, reason: "unreadable")
                } catch let error as SecureFile.IncompleteMove {
                    Self.log.error("moving the passwords database aside failed part way: \(error.description, privacy: .public)")
                    throw PasswordStoreError.moveAsideIncomplete(error.description)
                }
                Self.log.error("passwords database could not be opened with the Keychain key; moved aside")
            }
        }
        self.key = key
        self.movedAside = movedAside
        self.lock = lock

        try SecureFile.ensureOwnerOnlyFile(fileURL)
        // Converts an older (rollback-journal) file to WAL; needs a moment alone with the file.
        let pool = try Self.openPool(fileURL)
        database = pool
        do {
            // GRDB's WAL setup sets synchronous = NORMAL on the writer, after `prepareDatabase`:
            // in WAL that can lose the last commits (a just-saved login) on power loss. FULL
            // syncs the WAL at every commit. The pool's readers are read-only.
            try pool.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA synchronous = FULL") }
            try Self.migrator.migrate(pool)
            // The connection kept is checked the way `inspect` judged the file: its key check
            // opens with the key, or it holds nothing yet and gets one.
            try pool.write { db in
                if let check = try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'keyCheck'") {
                    guard LoginCrypto.verifyKeyCheck(check, key: key) else {
                        throw PasswordStoreError.databaseUnavailable("the passwords file changed while it was being opened")
                    }
                } else {
                    guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM login") == 0 else {
                        throw PasswordStoreError.databaseUnavailable("the passwords file changed while it was being opened")
                    }
                    try db.execute(sql: "INSERT INTO meta (key, value) VALUES ('keyCheck', ?)",
                                   arguments: [LoginCrypto.sealKeyCheck(key)])
                }
            }
        } catch let error as DatabaseError {
            try? pool.close()
            throw PasswordStoreError.databaseUnavailable("SQLite error \(error.resultCode.rawValue)")
        } catch {
            try? pool.close()
            throw error
        }
        // The new file is set up: other stores may open it again.
        if exclusive { lock.lockShared() }
        // SQLite gives its side files the database's mode; make sure of it.
        try SecureFile.limitSideFilesToOwner(of: fileURL)
    }

    /// Closes the database and lets go of the lock. The store can't be used afterwards.
    public func close() throws {
        defer { lock.unlock() }
        try database.close()
    }

    enum Format { case empty, notSQLite, rollbackJournal, wal }

    /// What the file's header says, without opening it in SQLite.
    static func format(of url: URL) -> Format {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .notSQLite }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), !header.isEmpty else { return .empty }
        guard header.count == 20, header.prefix(16) == Data("SQLite format 3\0".utf8) else { return .notSQLite }
        return header[18] == 2 && header[19] == 2 ? .wal : .rollbackJournal
    }

    private static func openPool(_ url: URL) throws -> DatabasePool {
        do {
            return try DatabasePool(path: url.path, configuration: configuration())
        } catch let error as DatabaseError {
            // Locked by another process, or WAL couldn't be turned on just now.
            throw PasswordStoreError.databaseUnavailable("SQLite error \(error.resultCode.rawValue)")
        }
    }

    /// Whether the file's header says WAL (format versions 2).
    static func isWAL(_ url: URL) -> Bool { format(of: url) == .wal }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.label = "iSmith.passwords"
        // Another process may be writing: wait rather than fail with SQLITE_BUSY.
        config.busyMode = .timeout(busyTimeout)
        // Deleted rows are overwritten with zeros rather than left in free pages.
        // The file is untrusted input: schema objects (triggers, views) may not call functions
        // with side effects. Run on every connection (the writer and each reader).
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA secure_delete = ON")
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
            // Every commit synced (a pool's writer is set again after GRDB's WAL setup).
            try db.execute(sql: "PRAGMA synchronous = FULL")
        }
        return config
    }

    /// Throws `orphanedSideFiles` when the database is missing but its side files aren't.
    private static func refuseOrphanedSideFiles(_ url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let left = SecureFile.sideFiles(of: url).filter { FileManager.default.fileExists(atPath: $0.path) }
        guard left.isEmpty else {
            log.error("passwords database missing but \(left.count, privacy: .public) of its side files are there; nothing changed")
            throw PasswordStoreError.orphanedSideFiles(left.map(\.path))
        }
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

    enum Inspection: Equatable {
        /// Opens with this key: its key check verifies, or it holds no logins yet.
        case usable
        /// Holds logins sealed with another key (or, without a key, any logins at all).
        case wrongKey
        /// Not a SQLite database, damaged, or not a passwords database.
        case notOurs
        /// Couldn't be read just now (locked, a disk or permissions error); says nothing about
        /// the file itself.
        case unavailable(String)
    }

    /// A connection to an existing file that never writes rows to it. Read-write (with
    /// `query_only`) by default: a read-only connection can't open a WAL file whose `-shm` is gone
    /// (a copy set aside after its last connection closed), and a read-write one replays a `-wal`
    /// left by a crash. Closing it may checkpoint committed WAL pages into the file, which loses
    /// nothing. `readOnly` (for `existingOnly`, which requires the side files) never checkpoints
    /// or removes anything.
    static func openForReading(_ url: URL, readOnly: Bool = false) throws -> DatabaseQueue {
        var config = configuration()
        if readOnly {
            config.readonly = true
        } else {
            config.prepareDatabase { db in try db.execute(sql: "PRAGMA query_only = ON") }
        }
        return try DatabaseQueue(path: url.path, configuration: config)
    }

    /// What an existing database file is, judged by reading it. A missing key can open only an
    /// empty database. See `openForReading` for what `readOnly` changes.
    static func inspect(_ url: URL, key: SymmetricKey?, readOnly: Bool = false) -> Inspection {
        do {
            let queue = try openForReading(url, readOnly: readOnly)
            defer { try? queue.close() }
            return try queue.read { db in
                guard try db.tableExists("meta"), try db.tableExists("login") else {
                    // Created but never migrated (or not ours): usable only if it holds nothing.
                    let empty = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table'")
                        .allSatisfy { $0.hasPrefix("sqlite_") || $0 == "grdb_migrations" }
                    return empty ? .usable : .notOurs
                }
                if let check = try Data.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'keyCheck'") {
                    guard let key else { return .wrongKey }
                    return LoginCrypto.verifyKeyCheck(check, key: key) ? .usable : .wrongKey
                }
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM login") == 0 ? .usable : .wrongKey
            }
        } catch let error as DatabaseError {
            switch error.resultCode {
            case .SQLITE_NOTADB, .SQLITE_CORRUPT, .SQLITE_FORMAT, .SQLITE_ERROR:
                // Not a database, damaged, or tables we can't read ("no such column").
                return .notOurs
            default:
                // Busy, locked, can't open, I/O or permission errors: nothing to do with the file.
                return .unavailable("SQLite error \(error.resultCode.rawValue)")
            }
        } catch {
            return .unavailable(String(describing: type(of: error)))
        }
    }

    // MARK: Health

    /// How many rows the file holds and how many of them decrypt. Counts only; nothing secret.
    public struct Health: Equatable, Sendable {
        public var rows: Int
        public var unreadable: Int
        public var readable: Int { rows - unreadable }

        public init(rows: Int, unreadable: Int) {
            self.rows = rows
            self.unreadable = unreadable
        }
    }

    public func health() throws -> Health {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM login")
            return Health(rows: rows.count, unreadable: rows.filter { decode($0) == nil }.count)
        }
    }

    // MARK: Copies set aside

    /// Earlier copies of the store that were moved aside (`passwords.unreadable-<time>.sqlite`),
    /// newest first.
    public static func setAsideCopies(of fileURL: URL) -> [URL] {
        let dir = fileURL.deletingLastPathComponent()
        let base = fileURL.deletingPathExtension().lastPathComponent + ".unreadable-"
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        // "unreadable-<stamp>[-<n>].sqlite": newest first, so when two copies hold the same login
        // the newer one is the one restored.
        func order(_ name: String) -> (Int, Int) {
            let middle = name.dropFirst(base.count).dropLast(fileURL.pathExtension.count + 1)
            let parts = middle.split(separator: "-").map { Int($0) ?? 0 }
            return (parts.first ?? 0, parts.count > 1 ? parts[1] : 1)
        }
        return names.filter { $0.hasPrefix(base) && $0.hasSuffix("." + fileURL.pathExtension) }
            .sorted { order($0) > order($1) }
            .map { dir.appendingPathComponent($0) }
    }

    /// Whether `recover(from:)` already went through this copy. Each copy is restored once, so
    /// a login deleted after it was restored doesn't come back at the next launch.
    public func wasRecovered(_ copy: URL) throws -> Bool {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM meta WHERE key = ?", arguments: ["recovered:" + copy.lastPathComponent]) ?? 0 > 0
        }
    }

    /// What `recover(from:)` did.
    public struct Recovery: Equatable, Sendable {
        /// Logins added to the store from the copy.
        public var restored = 0
        /// Logins of the copy the store already has (same id, or same site and username).
        public var alreadyThere = 0
        /// Rows of the copy that don't decrypt with this store's key.
        public var unreadable = 0
        /// The store as it was before the logins were added (only when some were).
        public var backup: URL?
    }

    /// Adds the logins of an earlier copy of the store (one moved aside) that open with this
    /// store's key and aren't in the store yet. Nothing is removed or overwritten: a login the
    /// store already has (by id, or by site and username) keeps the store's version, and the copy
    /// itself is only read. Before anything is added the store is backed up next to itself as
    /// `passwords.before-restore-<time>.sqlite`. Returns nil when the copy was sealed with another
    /// key (or isn't a passwords database), so nothing in it can be read; throws
    /// `databaseUnavailable` when it can't be read just now. The copy is marked as gone through
    /// (`wasRecovered`); callers restore each copy once.
    public func recover(from copy: URL) throws -> Recovery? {
        guard openMode.isApp else { throw PasswordStoreError.appOnly }
        switch Self.inspect(copy, key: key) {
        case .usable: break
        case .wrongKey, .notOurs: return nil
        case .unavailable(let why): throw PasswordStoreError.databaseUnavailable(why)
        }
        let source = try Self.openForReading(copy)
        defer { try? source.close() }
        let (rows, neverSave) = try source.read { db -> ([Row], [Row]) in
            guard try db.tableExists("login") else { return ([], []) }
            let never = try db.tableExists("neverSave") ? try Row.fetchAll(db, sql: "SELECT * FROM neverSave") : []
            return (try Row.fetchAll(db, sql: "SELECT * FROM login"), never)
        }
        var result = Recovery()
        var toAdd: [Login] = []
        try database.read { db in
            for row in rows {
                guard let login = decode(row) else {
                    result.unreadable += 1
                    continue
                }
                let sameID = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM login WHERE id = ?", arguments: [login.id.uuidString]) ?? 0) > 0
                let sameLogin = try existing(db, origin: login.origin, username: login.username) != nil
                if sameID || sameLogin || toAdd.contains(where: { $0.origin == login.origin && $0.username == login.username }) {
                    result.alreadyThere += 1
                } else {
                    toAdd.append(login)
                }
            }
        }
        let marker = "recovered:" + copy.lastPathComponent
        if !toAdd.isEmpty { result.backup = try backUp(reason: "before-restore") }
        Self.testHook?("recover.beforeWrite")
        let added = try database.write { db -> Int in
            try db.execute(sql: "INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)",
                           arguments: [marker, Data(String(Date().timeIntervalSince1970).utf8)])
            var added = 0
            for login in toAdd {
                // Checked again in this transaction: a login saved meanwhile (by another
                // process, say) is the current one and wins.
                let sameID = (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM login WHERE id = ?", arguments: [login.id.uuidString]) ?? 0) > 0
                let sameLogin = try existing(db, origin: login.origin, username: login.username) != nil
                if sameID || sameLogin { continue }
                try insert(db, login)
                added += 1
            }
            for row in neverSave {
                let origin: String? = row["origin"]
                let created: Double? = row["created"]
                guard let origin, Origin(string: origin) != nil else { continue }
                try db.execute(sql: "INSERT OR IGNORE INTO neverSave (origin, created) VALUES (?, ?)",
                               arguments: [origin, created ?? Date().timeIntervalSince1970])
            }
            return added
        }
        result.alreadyThere += toAdd.count - added
        result.restored = added
        Self.log.notice("restored \(result.restored, privacy: .public) logins from a copy set aside; \(result.alreadyThere, privacy: .public) already there, \(result.unreadable, privacy: .public) unreadable")
        return result
    }

    /// A consistent copy of the store next to it, owner-only from the start.
    func backUp(reason: String) throws -> URL {
        guard openMode.isApp else { throw PasswordStoreError.appOnly }
        let stamp = Int(Date().timeIntervalSince1970)
        let base = fileURL.deletingPathExtension()
        var target = base.appendingPathExtension("\(reason)-\(stamp).\(fileURL.pathExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = base.appendingPathExtension("\(reason)-\(stamp)-\(n).\(fileURL.pathExtension)")
            n += 1
        }
        // The empty file is made 0600 first, so the copy is never readable by others.
        try SecureFile.ensureOwnerOnlyFile(target)
        // The backup reads through the pool, so it includes what's still in the WAL. Closing the
        // destination checkpoints it, so the copy is one self-contained file.
        let destination = try DatabaseQueue(path: target.path, configuration: Self.configuration())
        try database.backup(to: destination)
        try destination.close()
        return target
    }

    // MARK: Reading

    /// Every readable login, by site and then username. Rows that fail to decrypt are skipped and
    /// counted by `unreadableCount()`.
    public func allLogins() throws -> [Login] {
        try database.read { db in try Row.fetchAll(db, sql: "SELECT * FROM login").compactMap(decode) }
            .sorted(by: Self.listOrder)
    }

    public func login(id: UUID) throws -> Login? {
        try database.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM login WHERE id = ?", arguments: [id.uuidString]).flatMap(decode)
        }
    }

    /// Rows that exist but can't be decrypted with the current key (tampered or damaged).
    public func unreadableCount() throws -> Int {
        try database.read { db in try Row.fetchAll(db, sql: "SELECT * FROM login").filter { decode($0) == nil }.count }
    }

    /// Logins that may be offered on a frame of `origin`: exact matches first, then same-site
    /// ones, each most recently used first. See `Origin` for the rules.
    public func logins(for origin: Origin) throws -> [LoginMatch] {
        try database.read { db -> [LoginMatch] in
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
        try database.write { db in
            guard try existing(db, origin: origin, username: username) == nil else { throw PasswordStoreError.duplicate }
            try insert(db, login)
        }
        return login
    }

    /// Saves a login's origin, username and password (and dates). Changing the password moves
    /// `updated` to now. Throws `.duplicate` if the new origin and username belong to another login.
    @discardableResult
    public func update(_ login: Login, date: Date = Date()) throws -> Login {
        try database.write { db in
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
        try database.write { db in
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
        try database.write { db in try db.execute(sql: "DELETE FROM login WHERE id = ?", arguments: [id.uuidString]) }
    }

    /// Records that a login was filled or signed in with.
    public func markUsed(id: UUID, date: Date = Date()) throws {
        try database.write { db in
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
        try database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO neverSave (origin, created) VALUES (?, ?)",
                           arguments: [origin.serialized, date.timeIntervalSince1970])
        }
    }

    public func removeNeverSave(_ origin: Origin) throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM neverSave WHERE origin = ?", arguments: [origin.serialized])
        }
    }

    /// "Never save" is per exact origin.
    public func isNeverSave(_ origin: Origin) throws -> Bool {
        try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM neverSave WHERE origin = ?", arguments: [origin.serialized]) ?? 0 > 0
        }
    }

    public func neverSaveOrigins() throws -> [Origin] {
        try database.read { db in
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
