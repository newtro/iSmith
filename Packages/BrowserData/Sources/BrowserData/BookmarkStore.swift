import Foundation
import GRDB

/// Bookmarks, one tree per space. Each space has two fixed root folders, "Bookmarks Bar" and
/// "Other Bookmarks", created the first time they are asked for. Roots can't be moved, renamed
/// or deleted; everything else lives in a folder.
///
/// Positions within a folder are always dense (0 to n-1) after every change. URLs are stored
/// exactly as given (bookmarklets and other schemes included) and matched exactly.
///
/// After each change `BookmarkStore.didChange` is posted on the main queue with the affected
/// spaces in `userInfo[BrowserDatabase.spacesKey]`; the app re-reads what it shows.
public final class BookmarkStore: @unchecked Sendable {
    /// Posted on the main queue after bookmarks change; see `BrowserDatabase.spacesKey`.
    public static let didChange = Notification.Name("BrowserData.BookmarkStore.didChange")

    private let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: Reading

    /// A space's root folder, created if it doesn't exist yet.
    public func root(_ root: BookmarkRoot, space: String) throws -> Bookmark {
        if let found = try writer.read({ db in try Self.findRoot(db, root, space: space) }) { return found }
        return try writer.write { db in try Self.ensureRoot(db, root, space: space) }
    }

    /// A folder's direct children, in order.
    public func children(of folderID: Int64) throws -> [Bookmark] {
        try writer.read { db in try Self.children(db, of: folderID) }
    }

    public func bookmark(id: Int64) throws -> Bookmark? {
        try writer.read { db in try Self.fetch(db, id) }
    }

    /// A space's whole tree: the Bookmarks Bar root, then Other Bookmarks, each with its contents.
    public func tree(space: String) throws -> [BookmarkTree] {
        _ = try root(.bar, space: space)
        _ = try root(.other, space: space)
        return try writer.read { db in
            let all = try Row.fetchAll(db, sql: "SELECT * FROM bookmark WHERE space = ? ORDER BY position, id",
                                       arguments: [space]).map(Self.decode)
            var byParent: [Int64: [Bookmark]] = [:]
            for b in all { if let p = b.parentID { byParent[p, default: []].append(b) } }
            func build(_ b: Bookmark) -> BookmarkTree {
                BookmarkTree(bookmark: b, children: (byParent[b.id] ?? []).map(build))
            }
            return BookmarkRoot.allCases.compactMap { r in all.first { $0.root == r }.map(build) }
        }
    }

    /// Bookmarks in a space whose URL is exactly `url` (for the star button), oldest first.
    public func bookmarks(space: String, url: String) throws -> [Bookmark] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM bookmark WHERE space = ? AND url = ? AND isFolder = 0 ORDER BY dateAdded, id
                """, arguments: [space, url]).map(Self.decode)
        }
    }

    /// Bookmarks (not folders) where every word of `query` appears in the title or URL,
    /// case-insensitively; newest first. `space` nil searches every space. An empty query
    /// returns nothing.
    public func search(_ query: String, space: String?, limit: Int) throws -> [Bookmark] {
        let words = searchWords(query)
        guard !words.isEmpty else { return [] }
        var sql = "SELECT * FROM bookmark WHERE isFolder = 0"
        var args: [DatabaseValueConvertible?] = []
        if let space { sql += " AND space = ?"; args.append(space) }
        for word in words { sql += " AND instr(search, ?) > 0"; args.append(word) }
        sql += " ORDER BY dateAdded DESC, id DESC LIMIT ?"
        args.append(limit)
        return try writer.read { db in
            try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args)).map(Self.decode)
        }
    }

    // MARK: Writing

    /// Adds a bookmark to `parent` (nil means the space's Bookmarks Bar) at `index` (nil or past
    /// the end appends).
    @discardableResult
    public func add(space: String, parent: Int64?, title: String, url: String, at index: Int? = nil) throws -> Bookmark {
        let added = try writer.write { db in
            try Self.insert(db, space: space, parent: parent, isFolder: false, title: title, url: url, at: index)
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
        return added
    }

    /// Adds a folder to `parent` (nil means the space's Bookmarks Bar) at `index`.
    @discardableResult
    public func addFolder(space: String, parent: Int64?, title: String, at index: Int? = nil) throws -> Bookmark {
        let added = try writer.write { db in
            try Self.insert(db, space: space, parent: parent, isFolder: true, title: title, url: nil, at: index)
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
        return added
    }

    /// Renames a bookmark or folder and/or changes a bookmark's URL (nil leaves a value as is).
    /// A URL for a folder throws `.notABookmark`; roots throw `.cannotModifyRoot`.
    public func update(_ id: Int64, title: String?, url: String?) throws {
        let space = try writer.write { db -> String in
            guard let b = try Self.fetch(db, id) else { throw BrowserDataError.notFound }
            guard b.root == nil else { throw BrowserDataError.cannotModifyRoot }
            if url != nil, b.isFolder { throw BrowserDataError.notABookmark }
            let newTitle = title ?? b.title
            let newURL = url ?? b.url
            try db.execute(sql: "UPDATE bookmark SET title = ?, url = ?, search = ?, dateModified = ? WHERE id = ?",
                           arguments: [newTitle, newURL, Self.search(newTitle, newURL), Date().seconds, id])
            return b.space
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
    }

    /// Moves a bookmark or folder into `parent` at `index`, which may be in another space: the
    /// whole subtree then moves to that space.
    ///
    /// `index` counts the destination's children as they are before the move, as drag and drop
    /// reports it (NSOutlineView's child index, SwiftUI's `onMove` offset): moving the first of
    /// three items to index 3 puts it last, and to index 1 leaves it where it is. Nil appends.
    /// Roots can't be moved, and a folder can't go into itself or its own folders.
    public func move(_ id: Int64, to parent: Int64, at index: Int?) throws {
        let spaces = try writer.write { db -> [String] in
            guard let node = try Self.fetch(db, id), let dest = try Self.fetch(db, parent) else {
                throw BrowserDataError.notFound
            }
            guard node.root == nil, let oldParent = node.parentID else { throw BrowserDataError.cannotModifyRoot }
            guard dest.isFolder else { throw BrowserDataError.notAFolder }
            var ancestor: Bookmark? = dest
            while let a = ancestor {
                if a.id == id { throw BrowserDataError.wouldCreateCycle }
                ancestor = try a.parentID.flatMap { try Self.fetch(db, $0) }
            }

            try db.execute(sql: "UPDATE bookmark SET parentID = NULL, position = -1 WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE bookmark SET position = position - 1 WHERE parentID = ? AND position > ?",
                           arguments: [oldParent, node.position])
            var target = index
            if oldParent == parent, let i = index, i > node.position { target = i - 1 }
            let position = try Self.makeRoom(db, in: parent, at: target)
            try db.execute(sql: "UPDATE bookmark SET parentID = ?, position = ? WHERE id = ?",
                           arguments: [parent, position, id])
            if dest.space != node.space {
                try db.execute(sql: """
                    WITH RECURSIVE sub(id) AS (
                        SELECT ? UNION ALL SELECT b.id FROM bookmark b JOIN sub ON b.parentID = sub.id)
                    UPDATE bookmark SET space = ? WHERE id IN (SELECT id FROM sub)
                    """, arguments: [id, dest.space])
            }
            return [node.space, dest.space]
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: spaces)
    }

    /// Copies a bookmark or folder (with everything in it) into `parent` at `index` (nil appends),
    /// possibly in another space, and returns the copy. Copies get new dates and no external id,
    /// so a later import still brings in the originals. A copied root becomes an ordinary folder.
    @discardableResult
    public func copy(_ id: Int64, to parent: Int64, at index: Int?) throws -> Bookmark {
        let (copy, space) = try writer.write { db -> (Bookmark, String) in
            guard let node = try Self.fetch(db, id), let dest = try Self.fetch(db, parent) else {
                throw BrowserDataError.notFound
            }
            guard dest.isFolder else { throw BrowserDataError.notAFolder }
            // Read the whole subtree first, so copying a folder into itself terminates.
            let snapshot = try Self.subtree(db, node)
            func insert(_ tree: BookmarkTree, into folder: Int64, at index: Int?) throws -> Bookmark {
                let b = tree.bookmark
                let copy = try Self.insert(db, space: dest.space, parent: folder, isFolder: b.isFolder,
                                           title: b.title, url: b.url, at: index)
                for child in tree.children { _ = try insert(child, into: copy.id, at: nil) }
                return copy
            }
            return (try insert(snapshot, into: parent, at: index), dest.space)
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
        return copy
    }

    /// Deletes a bookmark, or a folder and everything in it. Roots can't be deleted.
    public func delete(_ id: Int64) throws {
        let space = try writer.write { db -> String in
            guard let node = try Self.fetch(db, id) else { throw BrowserDataError.notFound }
            guard node.root == nil, let parent = node.parentID else { throw BrowserDataError.cannotModifyRoot }
            try db.execute(sql: "DELETE FROM bookmark WHERE id = ?", arguments: [id])
            try db.execute(sql: "UPDATE bookmark SET position = position - 1 WHERE parentID = ? AND position > ?",
                           arguments: [parent, node.position])
            return node.space
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
    }

    // MARK: Import

    /// Imports a tree of bookmarks and folders at the end of folder `parent` (in `space`), in one
    /// transaction.
    ///
    /// An item whose `externalID` already exists in the space is not added again, so importing the
    /// same file twice adds nothing. A folder found that way is merged into: its children are
    /// imported into the existing folder by the same rule. Items without an external id are always
    /// added.
    ///
    /// Mapping Brave's roots: the bookmark bar root's children go into the `.bar` root, the
    /// "other" root's children into the `.other` root, and the "mobile" root (when not empty)
    /// becomes a folder node titled "Mobile Bookmarks", with the mobile root's GUID as its external
    /// id, imported into the `.other` root. Map each Brave node to a `BookmarkImportNode` with its
    /// title, URL string (nil for folders), children, date added and GUID.
    @discardableResult
    public func importTree(_ nodes: [BookmarkImportNode], space: String, into parent: Int64) throws -> BookmarkImportResult {
        let result = try writer.write { db -> BookmarkImportResult in
            guard let dest = try Self.fetch(db, parent) else { throw BrowserDataError.notFound }
            guard dest.isFolder else { throw BrowserDataError.notAFolder }
            guard dest.space == space else { throw BrowserDataError.spaceMismatch }
            var result = BookmarkImportResult()
            func importNodes(_ nodes: [BookmarkImportNode], into folder: Int64) throws {
                for node in nodes {
                    if let ext = node.externalID, let existing = try Row.fetchOne(db, sql: """
                        SELECT * FROM bookmark WHERE space = ? AND externalID = ? ORDER BY id LIMIT 1
                        """, arguments: [space, ext]).map(Self.decode) {
                        if node.isFolder, existing.isFolder {
                            result.foldersMerged += 1
                            try importNodes(node.children, into: existing.id)
                        } else {
                            result.skipped += 1
                        }
                        continue
                    }
                    let added = try Self.insert(db, space: space, parent: folder, isFolder: node.isFolder,
                                                title: node.title, url: node.url, at: nil,
                                                dateAdded: node.dateAdded, externalID: node.externalID)
                    if node.isFolder {
                        result.foldersAdded += 1
                        try importNodes(node.children, into: added.id)
                    } else {
                        result.bookmarksAdded += 1
                    }
                }
            }
            try importNodes(nodes, into: parent)
            return result
        }
        ChangeNotifier.post(Self.didChange, object: self, spaces: [space])
        return result
    }

    // MARK: Helpers

    private static func findRoot(_ db: Database, _ root: BookmarkRoot, space: String) throws -> Bookmark? {
        try Row.fetchOne(db, sql: "SELECT * FROM bookmark WHERE space = ? AND root = ?",
                         arguments: [space, root.rawValue]).map(decode)
    }

    private static func ensureRoot(_ db: Database, _ root: BookmarkRoot, space: String) throws -> Bookmark {
        if let found = try findRoot(db, root, space: space) { return found }
        try db.execute(sql: """
            INSERT INTO bookmark (space, parentID, isFolder, title, url, search, position, dateAdded, root)
            VALUES (?, NULL, 1, ?, NULL, ?, ?, ?, ?)
            """, arguments: [space, root.title, search(root.title, nil), root == .bar ? 0 : 1, Date().seconds, root.rawValue])
        guard let made = try fetch(db, db.lastInsertedRowID) else { throw BrowserDataError.notFound }
        return made
    }

    private static func fetch(_ db: Database, _ id: Int64) throws -> Bookmark? {
        try Row.fetchOne(db, sql: "SELECT * FROM bookmark WHERE id = ?", arguments: [id]).map(decode)
    }

    private static func children(_ db: Database, of folder: Int64) throws -> [Bookmark] {
        try Row.fetchAll(db, sql: "SELECT * FROM bookmark WHERE parentID = ? ORDER BY position, id",
                         arguments: [folder]).map(decode)
    }

    private static func subtree(_ db: Database, _ node: Bookmark) throws -> BookmarkTree {
        BookmarkTree(bookmark: node, children: try children(db, of: node.id).map { try subtree(db, $0) })
    }

    /// Validates the parent, shifts its children to free `index` and inserts the row there.
    private static func insert(_ db: Database, space: String, parent: Int64?, isFolder: Bool, title: String,
                               url: String?, at index: Int?, dateAdded: Date? = nil,
                               externalID: String? = nil) throws -> Bookmark {
        let folder: Bookmark
        if let parent {
            guard let found = try fetch(db, parent) else { throw BrowserDataError.notFound }
            folder = found
        } else {
            folder = try ensureRoot(db, .bar, space: space)
        }
        guard folder.isFolder else { throw BrowserDataError.notAFolder }
        guard folder.space == space else { throw BrowserDataError.spaceMismatch }
        let position = try makeRoom(db, in: folder.id, at: index)
        try db.execute(sql: """
            INSERT INTO bookmark (space, parentID, isFolder, title, url, search, position, dateAdded, externalID)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [space, folder.id, isFolder, title, isFolder ? nil : url, search(title, url), position,
                             (dateAdded ?? Date()).seconds, externalID])
        guard let made = try fetch(db, db.lastInsertedRowID) else { throw BrowserDataError.notFound }
        return made
    }

    /// Clamps `index` to the folder's children (nil = end), shifts later children down one and
    /// returns the freed position.
    private static func makeRoom(_ db: Database, in folder: Int64, at index: Int?) throws -> Int {
        let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM bookmark WHERE parentID = ?", arguments: [folder]) ?? 0
        let position = min(max(index ?? count, 0), count)
        if position < count {
            try db.execute(sql: "UPDATE bookmark SET position = position + 1 WHERE parentID = ? AND position >= ?",
                           arguments: [folder, position])
        }
        return position
    }

    private static func search(_ title: String, _ url: String?) -> String {
        (title + "\n" + (url ?? "")).lowercased()
    }

    private static func decode(_ row: Row) -> Bookmark {
        Bookmark(id: row["id"], space: row["space"], parentID: row["parentID"], isFolder: row["isFolder"],
                 title: row["title"], url: row["url"], position: row["position"],
                 dateAdded: Date(seconds: row["dateAdded"]),
                 dateModified: (row["dateModified"] as Double?).map(Date.init(seconds:)),
                 externalID: row["externalID"], root: (row["root"] as String?).flatMap(BookmarkRoot.init(rawValue:)))
    }
}

/// A space's two fixed root folders.
public enum BookmarkRoot: String, CaseIterable, Sendable {
    case bar, other

    /// The folder's title: "Bookmarks Bar" or "Other Bookmarks".
    public var title: String {
        switch self {
        case .bar: return "Bookmarks Bar"
        case .other: return "Other Bookmarks"
        }
    }
}

/// A bookmark or folder.
public struct Bookmark: Identifiable, Equatable, Sendable {
    public let id: Int64
    public let space: String
    /// Nil only for root folders.
    public let parentID: Int64?
    public let isFolder: Bool
    public let title: String
    /// Nil for folders. Kept exactly as given.
    public let url: String?
    /// Index within the parent folder, 0-based and dense.
    public let position: Int
    public let dateAdded: Date
    public let dateModified: Date?
    /// The id the item had where it was imported from (a Brave GUID, for one).
    public let externalID: String?
    /// Set only on the two root folders.
    public let root: BookmarkRoot?
}

/// A bookmark or folder with its contents.
public struct BookmarkTree: Equatable, Sendable {
    public let bookmark: Bookmark
    public let children: [BookmarkTree]
}

/// An item to import, independent of where it came from. `url` nil means a folder.
public struct BookmarkImportNode: Equatable, Sendable {
    public var title: String
    public var url: String?
    public var children: [BookmarkImportNode]
    public var dateAdded: Date?
    /// A stable id from the source (Brave's GUID), used to skip items already imported.
    public var externalID: String?

    public init(title: String, url: String?, children: [BookmarkImportNode] = [], dateAdded: Date? = nil,
                externalID: String? = nil) {
        self.title = title
        self.url = url
        self.children = children
        self.dateAdded = dateAdded
        self.externalID = externalID
    }

    public var isFolder: Bool { url == nil }
}

/// What an import did.
public struct BookmarkImportResult: Equatable, Sendable {
    public var bookmarksAdded = 0
    public var foldersAdded = 0
    /// Existing folders (matched by external id) that new children were merged into.
    public var foldersMerged = 0
    /// Items not added because their external id already exists in the space.
    public var skipped = 0

    public init(bookmarksAdded: Int = 0, foldersAdded: Int = 0, foldersMerged: Int = 0, skipped: Int = 0) {
        self.bookmarksAdded = bookmarksAdded
        self.foldersAdded = foldersAdded
        self.foldersMerged = foldersMerged
        self.skipped = skipped
    }
}
