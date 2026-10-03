import Foundation
import GRDB

/// The downloads panel's list, global across spaces (each record remembers the space it started
/// in). The app owns the live downloads and saves each record here as it changes; at launch it
/// calls `markInterruptedAsFailed()` so downloads cut off by quitting show as failed.
/// Posts `DownloadStore.didChange` on the main queue after each change.
public final class DownloadStore: @unchecked Sendable {
    /// Posted on the main queue after the list changes.
    public static let didChange = Notification.Name("BrowserData.DownloadStore.didChange")

    /// The error given to downloads that were in progress when the app last quit.
    public static let interruptedError = "Interrupted when iSmith quit"

    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    /// Inserts the record, or replaces the one with the same id.
    public func upsert(_ r: DownloadRecord) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT OR REPLACE INTO download
                    (id, space, sourceURL, filePath, fileName, state, bytesReceived, bytesExpected, startedAt, finishedAt, error)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [r.id.uuidString, r.space, r.sourceURL, r.filePath, r.fileName, r.state.rawValue,
                                 r.bytesReceived, r.bytesExpected, r.startedAt.seconds, r.finishedAt?.seconds, r.error])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: nil)
    }

    /// The newest `limit` records, newest first.
    public func all(limit: Int) throws -> [DownloadRecord] {
        try writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM download ORDER BY startedAt DESC, rowid DESC LIMIT ?",
                             arguments: [limit]).compactMap(Self.decode)
        }
    }

    public func record(id: UUID) throws -> DownloadRecord? {
        try writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM download WHERE id = ?", arguments: [id.uuidString]).flatMap(Self.decode)
        }
    }

    /// Removes one record (the file on disk is the app's business).
    public func remove(_ id: UUID) throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM download WHERE id = ?", arguments: [id.uuidString])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: nil)
    }

    /// Removes every record that isn't in progress (finished, failed and cancelled), as the
    /// panel's Clear button does.
    public func clearFinished() throws {
        try writer.write { db in
            try db.execute(sql: "DELETE FROM download WHERE state <> ?", arguments: [DownloadState.inProgress.rawValue])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: nil)
    }

    /// Marks every in-progress record as failed with `interruptedError`. Call once at launch.
    public func markInterruptedAsFailed(at date: Date = Date()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE download SET state = ?, error = ?, finishedAt = COALESCE(finishedAt, ?) WHERE state = ?",
                           arguments: [DownloadState.failed.rawValue, Self.interruptedError, date.seconds,
                                       DownloadState.inProgress.rawValue])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: nil)
    }

    private static func decode(_ row: Row) -> DownloadRecord? {
        guard let id = UUID(uuidString: row["id"]), let state = DownloadState(rawValue: row["state"]) else { return nil }
        return DownloadRecord(id: id, space: row["space"], sourceURL: row["sourceURL"], filePath: row["filePath"],
                              fileName: row["fileName"], state: state, bytesReceived: row["bytesReceived"],
                              bytesExpected: row["bytesExpected"], startedAt: Date(seconds: row["startedAt"]),
                              finishedAt: (row["finishedAt"] as Double?).map(Date.init(seconds:)), error: row["error"])
    }
}

public enum DownloadState: String, CaseIterable, Sendable {
    case inProgress, finished, failed, cancelled
}

/// One entry in the downloads list.
public struct DownloadRecord: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var space: String
    public var sourceURL: String?
    /// Where the file is (or will be) on disk.
    public var filePath: String?
    public var fileName: String
    public var state: DownloadState
    public var bytesReceived: Int64
    /// Nil when the server didn't say.
    public var bytesExpected: Int64?
    public var startedAt: Date
    public var finishedAt: Date?
    public var error: String?

    public init(id: UUID = UUID(), space: String, sourceURL: String?, filePath: String?, fileName: String,
                state: DownloadState = .inProgress, bytesReceived: Int64 = 0, bytesExpected: Int64? = nil,
                startedAt: Date = Date(), finishedAt: Date? = nil, error: String? = nil) {
        self.id = id
        self.space = space
        self.sourceURL = sourceURL
        self.filePath = filePath
        self.fileName = fileName
        self.state = state
        self.bytesReceived = bytesReceived
        self.bytesExpected = bytesExpected
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.error = error
    }
}
