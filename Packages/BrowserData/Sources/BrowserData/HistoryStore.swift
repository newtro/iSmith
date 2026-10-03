import Foundation
import GRDB

/// Browsing history, per space: one row per page address (`history_url`) with its counts, and one
/// row per visit (`history_visit`).
///
/// Only http and https addresses are recorded. Pages are aggregated per (space, address without
/// its `#fragment`): `page#a` and `page#b` are one row, stored as `page`. Everything else in the
/// address is kept as given. A url row's `visitCount`, `typedCount` and `lastVisit` always equal
/// what its remaining visit rows say, so deleting visits never leaves ranking on deleted visits.
public final class HistoryStore: @unchecked Sendable {
    /// Posted on the main queue after history changes; see `BrowserDatabase.spacesKey`.
    public static let didChange = Notification.Name("BrowserData.HistoryStore.didChange")

    /// Visits to the same page in the same space closer together than this are one visit
    /// (redirect bounces, reloads, single-page apps re-reporting the same address).
    public static let duplicateWindow: TimeInterval = 1

    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: Recording

    /// Records a visit to `url` in `space`. Non-http(s) addresses are ignored. A nil or empty
    /// title keeps the page's previous title. A typed visit (the user entered the address) counts
    /// toward `typedCount`, which ranks a page higher in the address bar.
    public func recordVisit(space: String, url: URL, title: String?, typed: Bool = false, at date: Date = Date()) throws {
        guard let page = PageAddress(url) else { return }
        let t = date.seconds
        let newTitle = title.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        try writer.write { db in
            let urlID: Int64
            if let row = try Row.fetchOne(db, sql: "SELECT id, title FROM history_url WHERE space = ? AND url = ?",
                                          arguments: [space, page.url]) {
                urlID = row["id"]
                if let newTitle {
                    try db.execute(sql: "UPDATE history_url SET title = ?, search = ? WHERE id = ?",
                                   arguments: [newTitle, page.search(title: newTitle), urlID])
                }
            } else {
                try db.execute(sql: """
                    INSERT INTO history_url (space, url, host, bare, title, search, lastVisit)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [space, page.url, page.host, page.bare, newTitle, page.search(title: newTitle), t])
                urlID = db.lastInsertedRowID
            }
            let nearby = try Row.fetchOne(db, sql: """
                SELECT id, typed FROM history_visit WHERE urlID = ? AND visitedAt > ? AND visitedAt < ?
                ORDER BY visitedAt DESC LIMIT 1
                """, arguments: [urlID, t - Self.duplicateWindow, t + Self.duplicateWindow])
            if let nearby {
                if typed, !(nearby["typed"] as Bool) {
                    try db.execute(sql: "UPDATE history_visit SET typed = 1 WHERE id = ?", arguments: [nearby["id"] as Int64])
                }
            } else {
                try db.execute(sql: "INSERT INTO history_visit (urlID, visitedAt, typed) VALUES (?, ?, ?)",
                               arguments: [urlID, t, typed])
            }
            try Self.refresh(db, urlIDs: [urlID])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
    }

    /// Sets the title of a page already in history (titles usually arrive after the visit).
    /// Does nothing if the page isn't in this space's history.
    public func updateTitle(space: String, url: URL, title: String) throws {
        guard let page = PageAddress(url) else { return }
        let changed = try writer.write { db -> Bool in
            try db.execute(sql: "UPDATE history_url SET title = ?, search = ? WHERE space = ? AND url = ?",
                           arguments: [title, page.search(title: title), space, page.url])
            return db.changesCount > 0
        }
        if changed { ChangeNotifier.post(Self.didChange, object: self, spaces: [space]) }
    }

    // MARK: Reading

    /// Visits newest first, for the history page. `space` nil searches every space. Every
    /// whitespace-separated word of `query` must appear (case-insensitively) in the page's title
    /// or address; an empty query matches everything. `before` pages through older visits.
    public func visits(space: String?, matching query: String, before: Date? = nil, limit: Int) throws -> [HistoryVisitRow] {
        var sql = """
            SELECT v.id AS visitID, v.urlID, u.space, u.url, u.title, v.visitedAt
            FROM history_visit v CROSS JOIN history_url u ON u.id = v.urlID WHERE 1
            """
        // CROSS JOIN keeps visits as the outer loop, read newest first from their date index, so
        // a page of results stops early instead of sorting the space's whole history.
        var args: [DatabaseValueConvertible?] = []
        if let space { sql += " AND u.space = ?"; args.append(space) }
        if let before { sql += " AND v.visitedAt < ?"; args.append(before.seconds) }
        for word in searchWords(query) { sql += " AND instr(u.search, ?) > 0"; args.append(word) }
        sql += " ORDER BY v.visitedAt DESC, v.id DESC LIMIT ?"
        args.append(limit)
        return try writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map { row in
                HistoryVisitRow(visitID: row["visitID"], urlID: row["urlID"], space: row["space"], url: row["url"],
                                title: row["title"], visitedAt: Date(seconds: row["visitedAt"]))
            }
        }
    }

    /// Address bar suggestions for `text`: pages where every word appears in the address or title.
    ///
    /// Ranking: pages from `space` come before other spaces' pages; then by frecency,
    /// `(visitCount + 3 × typedCount) / (1 + days since last visit / 7)`, multiplied by 4 when the
    /// text matches the start of the address ignoring the scheme and "www." (`isPrefixMatch`).
    /// A page in several spaces appears once, from its best-ranked space.
    public func suggestions(for text: String, space: String, limit: Int) throws -> [HistorySuggestion] {
        // A scheme or "www." typed at the front is not required to appear: "https://gitl" finds
        // https://www.gitlab.com.
        let rest = TypedText(text.trimmingCharacters(in: .whitespacesAndNewlines)).rest
        let words = searchWords(rest)
        guard !words.isEmpty, limit > 0 else { return [] }
        let prefix = rest.isEmpty ? "0" : "(bare >= :lo AND bare < :hi)"
        var sql = """
            SELECT space, url, title, visitCount, typedCount, lastVisit, \(prefix) AS isPrefix,
                (visitCount + 3.0 * typedCount) / (1.0 + max(0.0, :now - lastVisit) / 604800.0)
                    * (CASE WHEN \(prefix) THEN 4.0 ELSE 1.0 END) AS score
            FROM history_url WHERE 1
            """
        var args: [String: DatabaseValueConvertible?] = [
            "now": Date().seconds, "space": space, "fetch": limit * 4,
        ]
        if !rest.isEmpty {
            args["lo"] = rest
            args["hi"] = rest + "\u{10FFFF}"
        }
        for (i, word) in words.enumerated() {
            sql += " AND instr(search, :w\(i)) > 0"
            args["w\(i)"] = word
        }
        sql += " ORDER BY (space = :space) DESC, score DESC, lastVisit DESC LIMIT :fetch"
        let rows = try writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
        }
        var seen = Set<String>()
        var result: [HistorySuggestion] = []
        for row in rows {
            let url: String = row["url"]
            guard seen.insert(url).inserted else { continue }
            result.append(HistorySuggestion(space: row["space"], url: url, title: row["title"],
                                            visitCount: row["visitCount"], typedCount: row["typedCount"],
                                            lastVisit: Date(seconds: row["lastVisit"]), isPrefixMatch: row["isPrefix"]))
            if result.count == limit { break }
        }
        return result
    }

    /// The inline completion for the address bar (the grey text after the caret), or nil.
    ///
    /// Only for text of one or more characters with no whitespace. Completions are addresses
    /// without scheme or leading "www.", such as "github.com/" or "dev.azure.com/contoso-dev/x".
    /// A scheme or "www." the user typed is kept at the front, so the result always starts with
    /// what was typed (compared case-insensitively; the app restores the typed casing).
    ///
    /// Without a "/" in the text the completion is a host: the most typed, then most visited host
    /// that starts with the text, plus "/". Once the text has a "/", it is the most typed, then
    /// most visited page whose address starts with the text. The current space's history is
    /// preferred; other spaces are used only when it has no candidate. Nil when nothing would be
    /// added to what was typed.
    public func inlineCompletion(for text: String, space: String) throws -> String? {
        guard !text.isEmpty, !text.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        let typed = TypedText(text)
        let rest = typed.rest
        guard !rest.isEmpty else { return nil }
        let args: [String: DatabaseValueConvertible?] = [
            "lo": rest, "hi": rest + "\u{10FFFF}", "space": space, "len": rest.count,
        ]
        let candidate: String? = try writer.read { db in
            if rest.contains("/") {
                return try String.fetchOne(db, sql: """
                    SELECT bare FROM history_url WHERE bare >= :lo AND bare < :hi
                    ORDER BY (space = :space) DESC, typedCount DESC, visitCount DESC, lastVisit DESC, length(bare)
                    LIMIT 1
                    """, arguments: StatementArguments(args))
            } else {
                return try String.fetchOne(db, sql: """
                    SELECT substr(bare, 1, instr(bare, '/')) AS hostPart FROM history_url
                    WHERE bare >= :lo AND bare < :hi
                    GROUP BY (space = :space), hostPart
                    ORDER BY (space = :space) DESC, SUM(typedCount) DESC, SUM(visitCount) DESC, MAX(lastVisit) DESC,
                        length(hostPart)
                    LIMIT 1
                    """, arguments: StatementArguments(args))
            }
        }
        guard let candidate, candidate.count > rest.count,
              candidate.lowercased().hasPrefix(rest.lowercased()) else { return nil }
        return typed.prefix + candidate
    }

    // MARK: Deleting

    /// Deletes these visits. Pages left with no visits are removed; the others' counts follow.
    public func delete(visitIDs: [Int64]) throws {
        guard !visitIDs.isEmpty else { return }
        let spaces = try writer.write { db -> [String] in
            var urlIDs: [Int64] = []
            var spaces: [String] = []
            for chunk in visitIDs.chunked(500) {
                let marks = Self.marks(chunk.count)
                let rows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT v.urlID, u.space FROM history_visit v JOIN history_url u ON u.id = v.urlID
                    WHERE v.id IN (\(marks))
                    """, arguments: StatementArguments(chunk))
                urlIDs += rows.map { $0["urlID"] }
                spaces += rows.map { $0["space"] }
                try db.execute(sql: "DELETE FROM history_visit WHERE id IN (\(marks))", arguments: StatementArguments(chunk))
            }
            try Self.refresh(db, urlIDs: urlIDs)
            return spaces
        }
        if !spaces.isEmpty { ChangeNotifier.post(Self.didChange, object: self, spaces: spaces) }
    }

    /// Deletes a page and all its visits from a space's history (the fragment is ignored).
    public func deleteURL(space: String, url: URL) throws {
        guard let page = PageAddress(url) else { return }
        try writer.write { db in
            try db.execute(sql: "DELETE FROM history_url WHERE space = ? AND url = ?", arguments: [space, page.url])
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
    }

    /// Clears history: of one space or (nil) all, and either everything or (with `since`) only
    /// visits at or after that date.
    public func clear(space: String?, since: Date?) throws {
        try writer.write { db in
            guard let since else {
                if let space {
                    try db.execute(sql: "DELETE FROM history_url WHERE space = ?", arguments: [space])
                } else {
                    try db.execute(sql: "DELETE FROM history_url")
                }
                return
            }
            var filter = "1"
            var args: [DatabaseValueConvertible?] = []
            if let space { filter += " AND u.space = ?"; args.append(space) }
            filter += " AND v.visitedAt >= ?"
            args.append(since.seconds)
            let urlIDs = try Int64.fetchAll(db, sql: """
                SELECT DISTINCT v.urlID FROM history_visit v JOIN history_url u ON u.id = v.urlID WHERE \(filter)
                """, arguments: StatementArguments(args))
            try db.execute(sql: """
                DELETE FROM history_visit WHERE id IN (
                    SELECT v.id FROM history_visit v JOIN history_url u ON u.id = v.urlID WHERE \(filter))
                """, arguments: StatementArguments(args))
            try Self.refresh(db, urlIDs: urlIDs)
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: space.map { [$0] })
    }

    /// Removes visits older than `date` in every space, and pages left with no visits.
    public func prune(olderThan date: Date) throws {
        let changed = try writer.write { db -> Bool in
            let urlIDs = try Int64.fetchAll(db, sql: "SELECT DISTINCT urlID FROM history_visit WHERE visitedAt < ?",
                                            arguments: [date.seconds])
            try db.execute(sql: "DELETE FROM history_visit WHERE visitedAt < ?", arguments: [date.seconds])
            try Self.refresh(db, urlIDs: urlIDs)
            return !urlIDs.isEmpty
        }
        if changed { ChangeNotifier.post(Self.didChange, object: self, spaces: nil) }
    }

    // MARK: Helpers

    /// Recomputes counts and last visit from the visit rows, and removes pages with no visits.
    private static func refresh(_ db: Database, urlIDs: [Int64]) throws {
        for chunk in Array(Set(urlIDs)).chunked(500) {
            let marks = Self.marks(chunk.count)
            try db.execute(sql: """
                UPDATE history_url SET
                    visitCount = (SELECT COUNT(*) FROM history_visit WHERE urlID = history_url.id),
                    typedCount = (SELECT COUNT(*) FROM history_visit WHERE urlID = history_url.id AND typed = 1),
                    lastVisit = COALESCE((SELECT MAX(visitedAt) FROM history_visit WHERE urlID = history_url.id), lastVisit)
                WHERE id IN (\(marks))
                """, arguments: StatementArguments(chunk))
            try db.execute(sql: "DELETE FROM history_url WHERE id IN (\(marks)) AND visitCount = 0",
                           arguments: StatementArguments(chunk))
        }
    }

    private static func marks(_ n: Int) -> String {
        Array(repeating: "?", count: n).joined(separator: ",")
    }
}

/// One visit, for the history page.
public struct HistoryVisitRow: Identifiable, Equatable, Sendable {
    public var id: Int64 { visitID }
    public let visitID: Int64
    public let urlID: Int64
    public let space: String
    public let url: String
    public let title: String?
    public let visitedAt: Date
}

/// One page suggested in the address bar.
public struct HistorySuggestion: Equatable, Sendable {
    public let space: String
    public let url: String
    public let title: String?
    public let visitCount: Int
    public let typedCount: Int
    public let lastVisit: Date
    /// The typed text matches the start of the address, ignoring scheme and "www.".
    public let isPrefixMatch: Bool
}

/// A history address and its derived forms.
struct PageAddress {
    /// The address as given, without its fragment.
    let url: String
    /// Lowercase host.
    let host: String
    /// The address without scheme, user info or leading "www.", authority lowercased, always with
    /// a "/" after the authority: "github.com/scott/repo?tab=1". Used for prefix matching.
    let bare: String

    init?(_ url: URL) {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else { return nil }
        var string = url.absoluteString
        if let hash = string.firstIndex(of: "#") { string = String(string[..<hash]) }
        self.url = string
        self.host = host.lowercased()

        var afterScheme = Substring(string)
        if let range = string.range(of: "://") { afterScheme = string[range.upperBound...] }
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterScheme.endIndex
        var authority = afterScheme[..<authorityEnd].lowercased()
        if let at = authority.lastIndex(of: "@") { authority = String(authority[authority.index(after: at)...]) }
        if authority.hasPrefix("www.") { authority.removeFirst(4) }
        var path = String(afterScheme[authorityEnd...])
        if !path.hasPrefix("/") { path = "/" + path }
        bare = authority + path
    }

    func search(title: String?) -> String {
        (url + "\n" + bare + "\n" + (title ?? "")).lowercased()
    }
}

/// Address bar text split into what the user typed before the host ("https://", "www.") and the
/// rest, which is compared with `PageAddress.bare`.
struct TypedText {
    let prefix: String
    let rest: String

    init(_ text: String) {
        var rest = Substring(text)
        for lead in ["https://", "http://", "www."] where rest.lowercased().hasPrefix(lead) {
            rest = rest.dropFirst(lead.count)
        }
        prefix = String(text.prefix(text.count - rest.count))
        self.rest = String(rest)
    }
}

extension Array {
    func chunked(_ size: Int) -> [ArraySlice<Element>] {
        stride(from: 0, to: count, by: size).map { self[$0..<Swift.min($0 + size, count)] }
    }
}
