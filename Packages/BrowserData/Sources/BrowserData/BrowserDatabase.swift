import Foundation
import GRDB
import os

/// The browser's own data in one SQLite file, `browser.sqlite`: history (per space), bookmarks,
/// site settings and the downloads list (shared by every space). Spaces are plain string ids such
/// as "contoso"; this package never checks them against a list.
///
/// Before the migration that merges the old per-space bookmarks into one tree runs on a file that
/// has some, the file is copied to `browser.before-global-bookmarks-<time>.sqlite` (owner-only).
/// If that copy can't be made, opening fails with `BrowserDataError.backupFailed` and the file
/// is left as it was. If the merge itself then fails, opening fails with
/// `BrowserDataError.migrationFailed` and the file is left as it was too (not moved aside).
///
/// Files are owner-only (folder 0700, database 0600). The file is opened as a GRDB
/// `DatabasePool` in WAL mode, so every store method is safe to call from any thread, and reads
/// (the address bar's suggestion queries, for one) run alongside writes.
///
/// If an existing file can't be opened or migrated because it is damaged or not a database, it is
/// moved aside as `browser.unreadable-<time>.sqlite` (with its side files) and a new, empty one
/// starts; `movedAside` says where it went. Errors that say nothing about the file itself (disk
/// full, permissions, busy) are thrown instead, and the file is left alone.
///
/// Change notifications: each store posts its `didChange` notification on the main queue after a
/// write commits, with the store as the object and the spaces affected in
/// `userInfo[BrowserDatabase.spacesKey]` (`[String]`; absent when any space may have changed).
public final class BrowserDatabase: @unchecked Sendable {
    /// `<dataDirectory>/browser.sqlite`.
    public static func defaultFileURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("browser.sqlite")
    }

    /// The `userInfo` key of every `didChange` notification: the affected spaces, as `[String]`.
    public static let spacesKey = "spaces"

    /// The database file, or nil for an in-memory database.
    public let fileURL: URL?
    /// Where an unreadable database was moved when this one opened, if it was.
    public let movedAside: URL?

    public let history: HistoryStore
    public let bookmarks: BookmarkStore
    public let sites: SiteSettingsStore
    public let downloads: DownloadStore
    /// The agent panel's threads, settings and activity log (v1.1).
    public let agent: AgentStore

    let writer: any DatabaseWriter
    private static let log = Logger(subsystem: "com.scottsmith.ismith", category: "browser-data")

    /// Opens (creating if needed) the database at `fileURL` and brings its schema up to date.
    public convenience init(fileURL: URL) throws {
        try SecureFile.prepareDirectory(fileURL.deletingLastPathComponent())
        var movedAside: URL?
        let pool: DatabasePool
        do {
            pool = try Self.open(fileURL)
        } catch where Self.isUnreadable(error) && FileManager.default.fileExists(atPath: fileURL.path) {
            movedAside = try SecureFile.moveAside(fileURL, reason: "unreadable")
            Self.log.error("browser database could not be opened (\(String(describing: error), privacy: .public)); moved aside")
            pool = try Self.open(fileURL)
        }
        self.init(writer: pool, fileURL: fileURL, movedAside: movedAside)
    }

    /// A private, empty database in memory, for tests and previews.
    public static func inMemory() throws -> BrowserDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        try migrator.migrate(queue)
        return BrowserDatabase(writer: queue, fileURL: nil, movedAside: nil)
    }

    private init(writer: any DatabaseWriter, fileURL: URL?, movedAside: URL?) {
        self.writer = writer
        self.fileURL = fileURL
        self.movedAside = movedAside
        history = HistoryStore(writer: writer)
        bookmarks = BookmarkStore(writer: writer)
        sites = SiteSettingsStore(writer: writer)
        downloads = DownloadStore(writer: writer)
        agent = AgentStore(writer: writer)
    }

    /// Deletes everything belonging to a space: its history and its agent threads. Bookmarks, site
    /// settings and downloads are shared by every space and stay.
    public func removeSpace(_ space: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM history_url WHERE space = ?", arguments: [space])
            try db.execute(sql: "DELETE FROM agent_thread WHERE space = ?", arguments: [space])
            try db.execute(sql: "DELETE FROM agent_space WHERE space = ?", arguments: [space])
            try db.execute(sql: "DELETE FROM agent_activity WHERE space = ?", arguments: [space])
        }
        ChangeNotifier.post(HistoryStore.didChange, object: history, spaces: [space])
        ChangeNotifier.post(AgentStore.didChange, object: agent, spaces: [space])
    }

    // MARK: Opening

    private static func open(_ url: URL) throws -> DatabasePool {
        try SecureFile.ensureOwnerOnlyFile(url)
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        do {
            let backup = try backUpBeforeGlobalBookmarks(pool, fileURL: url)
            do {
                try migrator.migrate(pool)
            } catch where backup != nil {
                // The file read fine and was just copied, so it isn't damaged: don't let the
                // failure pass for an unreadable file and have it moved aside.
                throw BrowserDataError.migrationFailed(String(describing: error))
            }
        } catch {
            try? pool.close()
            throw error
        }
        return pool
    }

    /// Copies the file aside before "v3-global-bookmarks" merges the per-space bookmarks, when
    /// there is something to merge: the old schema (a `space` column) with rows. Returns the copy,
    /// or nil when none was needed. A file that can't even be read throws as any open does (a
    /// damaged one is then moved aside whole). Once the copy has started, any failure throws
    /// `BrowserDataError.backupFailed` (never a `DatabaseError`, so the file isn't taken for
    /// unreadable and moved aside) and the migration doesn't run.
    @discardableResult
    static func backUpBeforeGlobalBookmarks(_ pool: DatabasePool, fileURL: URL) throws -> URL? {
        let needed = try pool.read { db -> Bool in
            guard try db.tableExists("bookmark"),
                  try db.columns(in: "bookmark").contains(where: { $0.name == "space" }) else { return false }
            return try Bool.fetchOne(db, sql: "SELECT EXISTS (SELECT 1 FROM bookmark)") ?? false
        }
        guard needed else { return nil }
        let target = SecureFile.unusedSibling(of: fileURL, tag: "before-global-bookmarks")
        do {
            try SecureFile.createOwnerOnlyFile(target)
        } catch {
            throw BrowserDataError.backupFailed(String(describing: error))
        }
        do {
            let copy = try DatabaseQueue(path: target.path)
            do {
                try pool.backup(to: copy)
                try copy.close()
            } catch {
                try? copy.close()
                throw error
            }
            for side in SecureFile.sideFiles(of: target) where FileManager.default.fileExists(atPath: side.path) {
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: side.path)
            }
            log.notice("backed up browser.sqlite before merging bookmarks: \(target.lastPathComponent, privacy: .public)")
            return target
        } catch {
            try? FileManager.default.removeItem(at: target)
            for side in SecureFile.sideFiles(of: target) { try? FileManager.default.removeItem(at: side) }
            throw BrowserDataError.backupFailed(String(describing: error))
        }
    }

    /// Whether an open failure means the file itself is bad (damaged, not a database, or a schema
    /// the migrations can't apply to), as opposed to the environment (disk, permissions, locks).
    private static func isUnreadable(_ error: Error) -> Bool {
        guard let error = error as? DatabaseError else { return false }
        let environmental: [ResultCode] = [
            .SQLITE_BUSY, .SQLITE_LOCKED, .SQLITE_FULL, .SQLITE_IOERR, .SQLITE_CANTOPEN,
            .SQLITE_PERM, .SQLITE_READONLY, .SQLITE_NOMEM, .SQLITE_AUTH, .SQLITE_INTERRUPT,
            .SQLITE_ABORT,
        ]
        return !environmental.contains(error.resultCode)
    }

    private static func configuration() -> Configuration {
        var config = Configuration()
        config.label = "iSmith.browser"
        config.busyMode = .timeout(5)
        // The file is untrusted input: schema objects (triggers, views) may not call functions
        // with side effects.
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA trusted_schema = OFF")
        }
        return config
    }

    /// Timestamps are stored as seconds since 1970 (REAL) so ranking can do arithmetic on them.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE history_url (
                    id INTEGER PRIMARY KEY,
                    space TEXT NOT NULL,
                    url TEXT NOT NULL,
                    host TEXT NOT NULL,
                    bare TEXT NOT NULL COLLATE NOCASE,
                    title TEXT,
                    search TEXT NOT NULL,
                    visitCount INTEGER NOT NULL DEFAULT 0,
                    typedCount INTEGER NOT NULL DEFAULT 0,
                    lastVisit REAL NOT NULL,
                    UNIQUE (space, url)
                );
                CREATE INDEX history_url_space_lastVisit ON history_url(space, lastVisit);
                CREATE INDEX history_url_space_host ON history_url(space, host);
                CREATE INDEX history_url_bare ON history_url(bare);
                CREATE TABLE history_visit (
                    id INTEGER PRIMARY KEY,
                    urlID INTEGER NOT NULL REFERENCES history_url(id) ON DELETE CASCADE,
                    visitedAt REAL NOT NULL,
                    typed INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX history_visit_url ON history_visit(urlID, visitedAt);
                CREATE INDEX history_visit_visitedAt ON history_visit(visitedAt);

                CREATE TABLE bookmark (
                    id INTEGER PRIMARY KEY,
                    space TEXT NOT NULL,
                    parentID INTEGER REFERENCES bookmark(id) ON DELETE CASCADE,
                    isFolder INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    url TEXT,
                    search TEXT NOT NULL,
                    position INTEGER NOT NULL,
                    dateAdded REAL NOT NULL,
                    dateModified REAL,
                    externalID TEXT,
                    root TEXT
                );
                CREATE INDEX bookmark_parent ON bookmark(parentID, position);
                CREATE UNIQUE INDEX bookmark_root ON bookmark(space, root) WHERE root IS NOT NULL;
                CREATE INDEX bookmark_space_url ON bookmark(space, url);
                CREATE INDEX bookmark_space_externalID ON bookmark(space, externalID) WHERE externalID IS NOT NULL;

                CREATE TABLE site_permission (
                    origin TEXT NOT NULL,
                    permission TEXT NOT NULL,
                    decision TEXT NOT NULL,
                    updated REAL NOT NULL,
                    PRIMARY KEY (origin, permission)
                );
                CREATE TABLE site_zoom (
                    host TEXT PRIMARY KEY NOT NULL,
                    factor REAL NOT NULL
                );
                CREATE TABLE app_link (
                    scheme TEXT PRIMARY KEY NOT NULL,
                    decision TEXT NOT NULL,
                    updated REAL NOT NULL
                );

                CREATE TABLE download (
                    id TEXT PRIMARY KEY NOT NULL,
                    space TEXT NOT NULL,
                    sourceURL TEXT,
                    filePath TEXT,
                    fileName TEXT NOT NULL,
                    state TEXT NOT NULL,
                    bytesReceived INTEGER NOT NULL,
                    bytesExpected INTEGER,
                    startedAt REAL NOT NULL,
                    finishedAt REAL,
                    error TEXT
                );
                CREATE INDEX download_startedAt ON download(startedAt);
                """)
        }
        // v1.1: the agent panel.
        migrator.registerMigration("v2-agent") { db in
            try db.execute(sql: """
                CREATE TABLE agent_thread (
                    id TEXT PRIMARY KEY NOT NULL,
                    space TEXT NOT NULL,
                    backend TEXT NOT NULL,
                    name TEXT NOT NULL,
                    createdAt REAL NOT NULL,
                    updatedAt REAL NOT NULL,
                    model TEXT
                );
                CREATE INDEX agent_thread_space ON agent_thread(space, updatedAt);
                CREATE TABLE agent_space (
                    space TEXT PRIMARY KEY NOT NULL,
                    mode TEXT,
                    workingFolder TEXT,
                    model TEXT
                );
                CREATE TABLE agent_activity (
                    id INTEGER PRIMARY KEY,
                    space TEXT NOT NULL,
                    threadID TEXT,
                    at REAL NOT NULL,
                    tool TEXT NOT NULL,
                    tabTitle TEXT,
                    tabURL TEXT,
                    target TEXT NOT NULL,
                    outcome TEXT NOT NULL
                );
                CREATE INDEX agent_activity_space_at ON agent_activity(space, at);
                """)
        }
        // 2026-10-06: bookmarks are shared by every space. The per-space copies are merged into
        // one tree (see `BookmarkMerge`; `open` backs the file up first).
        migrator.registerMigration("v3-global-bookmarks") { db in
            try BookmarkMerge.migrate(db)
        }
        return migrator
    }
}

/// Errors from the stores' writes.
public enum BrowserDataError: Error, Equatable, CustomStringConvertible {
    /// The bookmark (or folder) no longer exists.
    case notFound
    /// The target of an add, move, copy or import is a bookmark, not a folder.
    case notAFolder
    /// A URL was given for a folder.
    case notABookmark
    /// Root folders can't be moved, renamed or deleted.
    case cannotModifyRoot
    /// A folder can't be moved into itself or one of its own folders.
    case wouldCreateCycle
    /// A value out of range (for example a zoom factor of zero).
    case invalidValue
    /// The copy of the database made before a migration that rewrites data couldn't be made, so
    /// the migration didn't run and the file is as it was.
    case backupFailed(String)
    /// A migration that rewrites data failed on a file that reads fine (and was backed up). The
    /// file is left as it was rather than moved aside.
    case migrationFailed(String)

    public var description: String {
        switch self {
        case .notFound: return "The bookmark no longer exists."
        case .notAFolder: return "Bookmarks can only be put in folders."
        case .notABookmark: return "A folder has no address."
        case .cannotModifyRoot: return "The Bookmarks Bar and Other Bookmarks folders can't be changed."
        case .wouldCreateCycle: return "A folder can't be moved into itself."
        case .invalidValue: return "The value is out of range."
        case .migrationFailed(let why): return "The browser data couldn't be updated, so it was left as it was: \(why)"
        case .backupFailed(let why): return "The browser data couldn't be backed up before updating it, so it wasn't changed: \(why)"
        }
    }
}

/// Posts a store's change notification on the main queue, after the write has committed.
enum ChangeNotifier {
    static func post(_ name: Notification.Name, object: AnyObject, spaces: [String]?) {
        let info: [AnyHashable: Any]? = spaces.map { [BrowserDatabase.spacesKey: Array(Set($0)).sorted()] }
        let sender = UncheckedBox(object)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: sender.value, userInfo: info)
        }
    }
}

struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

extension Date {
    var seconds: Double { timeIntervalSince1970 }
    init(seconds: Double) { self.init(timeIntervalSince1970: seconds) }
}

/// Splits user text into lowercase search words; every word must match.
func searchWords(_ text: String) -> [String] {
    text.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
}
