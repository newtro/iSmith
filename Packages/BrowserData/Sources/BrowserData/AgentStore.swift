import Foundation
import GRDB

/// The agent panel's own records (v1.1): each space's chat threads (the backend's thread id, a
/// name and dates, so the list survives a relaunch; the messages themselves stay with the
/// backend), each space's agent settings (mode, working folder, model), and the activity log of
/// every browser tool call. Posts `AgentStore.didChange` on the main queue after each change, with
/// the space in `userInfo[BrowserDatabase.spacesKey]`.
///
/// The log holds what a tool acted on (tab title and address, the element's role and name, a
/// typed text's length), never typed text itself or anything read from a page.
public final class AgentStore: @unchecked Sendable {
    public static let didChange = Notification.Name("BrowserData.AgentStore.didChange")

    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: Threads

    /// Adds a thread, or updates the one with the same id (its space never changes).
    public func saveThread(_ t: AgentThreadRecord) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO agent_thread (id, space, backend, name, createdAt, updatedAt, model)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET name = excluded.name, updatedAt = excluded.updatedAt, model = excluded.model
                """, arguments: [t.id, t.space, t.backend, t.name, t.createdAt.seconds, t.updatedAt.seconds, t.model])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [t.space])
    }

    /// A space's threads, most recently used first.
    public func threads(space: String, limit: Int = 200) throws -> [AgentThreadRecord] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agent_thread WHERE space = ? ORDER BY updatedAt DESC, rowid DESC LIMIT ?",
                             arguments: [space, limit]).map(Self.thread)
        }
    }

    public func thread(id: String) throws -> AgentThreadRecord? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM agent_thread WHERE id = ?", arguments: [id]).map(Self.thread)
        }
    }

    public func renameThread(id: String, name: String) throws {
        let space = try thread(id: id)?.space
        try writer.write { db in
            try db.execute(sql: "UPDATE agent_thread SET name = ? WHERE id = ?", arguments: [name, id])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: space.map { [$0] })
    }

    /// Marks a thread as just used (it moves to the top of the list).
    public func touchThread(id: String, at date: Date = Date()) throws {
        let space = try thread(id: id)?.space
        try writer.write { db in
            try db.execute(sql: "UPDATE agent_thread SET updatedAt = ? WHERE id = ?", arguments: [date.seconds, id])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: space.map { [$0] })
    }

    /// Removes a thread from the list (the backend keeps its own copy).
    public func removeThread(id: String) throws {
        let space = try thread(id: id)?.space
        try writer.write { db in
            try db.execute(sql: "DELETE FROM agent_thread WHERE id = ?", arguments: [id])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: space.map { [$0] })
    }

    private static func thread(_ row: Row) -> AgentThreadRecord {
        AgentThreadRecord(id: row["id"], space: row["space"], backend: row["backend"], name: row["name"],
                          createdAt: Date(seconds: row["createdAt"]), updatedAt: Date(seconds: row["updatedAt"]),
                          model: row["model"])
    }

    // MARK: Settings

    /// The space's saved settings, or nil if it has none yet (the app's defaults apply).
    public func settings(space: String) throws -> AgentSpaceSettings? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM agent_space WHERE space = ?", arguments: [space]).map { row in
                AgentSpaceSettings(space: row["space"], mode: row["mode"], workingFolder: row["workingFolder"], model: row["model"])
            }
        }
    }

    public func saveSettings(_ s: AgentSpaceSettings) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO agent_space (space, mode, workingFolder, model) VALUES (?, ?, ?, ?)
                """, arguments: [s.space, s.mode, s.workingFolder, s.model])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [s.space])
    }

    // MARK: Activity log

    @discardableResult
    public func log(_ entry: AgentActivity) throws -> Int64 {
        let id = try writer.write { db -> Int64 in
            try db.execute(sql: """
                INSERT INTO agent_activity (space, threadID, at, tool, tabTitle, tabURL, target, outcome)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [entry.space, entry.threadID, entry.at.seconds, entry.tool, entry.tabTitle,
                                 entry.tabURL, entry.target, entry.outcome.rawValue])
            return db.lastInsertedRowID
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [entry.space])
        return id
    }

    /// A space's newest log entries, newest first.
    public func activity(space: String, limit: Int = 500) throws -> [AgentActivity] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM agent_activity WHERE space = ? ORDER BY at DESC, id DESC LIMIT ?",
                             arguments: [space, limit]).compactMap { row in
                guard let outcome = AgentActivity.Outcome(rawValue: row["outcome"]) else { return nil }
                return AgentActivity(id: row["id"], space: row["space"], threadID: row["threadID"], at: Date(seconds: row["at"]),
                                     tool: row["tool"], tabTitle: row["tabTitle"], tabURL: row["tabURL"],
                                     target: row["target"], outcome: outcome)
            }
        }
    }

    /// Removes log entries older than `date` (at launch, as history does).
    public func pruneActivity(olderThan date: Date) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM agent_activity WHERE at < ?", arguments: [date.seconds])
        }
    }

    public func clearActivity(space: String) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM agent_activity WHERE space = ?", arguments: [space])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
    }
}

/// A chat thread in a space's list.
public struct AgentThreadRecord: Identifiable, Equatable, Sendable {
    /// The backend's thread id.
    public var id: String
    public var space: String
    /// Which backend runs it ("codex").
    public var backend: String
    public var name: String
    public var createdAt: Date
    public var updatedAt: Date
    public var model: String?

    public init(id: String, space: String, backend: String, name: String, createdAt: Date = Date(),
                updatedAt: Date = Date(), model: String? = nil) {
        (self.id, self.space, self.backend, self.name) = (id, space, backend, name)
        (self.createdAt, self.updatedAt, self.model) = (createdAt, updatedAt, model)
    }
}

/// A space's agent settings. `mode` is the app's mode name; nil fields use the app's defaults.
public struct AgentSpaceSettings: Equatable, Sendable {
    public var space: String
    public var mode: String?
    public var workingFolder: String?
    public var model: String?

    public init(space: String, mode: String? = nil, workingFolder: String? = nil, model: String? = nil) {
        (self.space, self.mode, self.workingFolder, self.model) = (space, mode, workingFolder, model)
    }
}

/// One browser tool call in a space's activity log.
public struct AgentActivity: Identifiable, Equatable, Sendable {
    public enum Outcome: String, Sendable, CaseIterable {
        /// The tool ran.
        case done
        /// It failed (no such element, the page went away).
        case failed
        /// The space's mode doesn't allow it.
        case blocked
        /// The user said no in the panel.
        case denied
        /// It's waiting for the user (an approval, a sign-in).
        case waiting
    }

    public var id: Int64?
    public var space: String
    public var threadID: String?
    public var at: Date
    public var tool: String
    public var tabTitle: String?
    public var tabURL: String?
    /// What it acted on: "button “Add to cart”", "https://…", "12 characters".
    public var target: String
    public var outcome: Outcome

    public init(id: Int64? = nil, space: String, threadID: String?, at: Date = Date(), tool: String,
                tabTitle: String?, tabURL: String?, target: String, outcome: Outcome) {
        (self.id, self.space, self.threadID, self.at, self.tool) = (id, space, threadID, at, tool)
        (self.tabTitle, self.tabURL, self.target, self.outcome) = (tabTitle, tabURL, target, outcome)
    }
}
