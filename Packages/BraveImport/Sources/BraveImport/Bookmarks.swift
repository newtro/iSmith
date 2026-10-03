import Foundation

/// A bookmark or folder, independent of Brave's file format. The app maps the tree into a space.
public struct BookmarkNode: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `url` is kept as Brave stored it (bookmarklets and odd schemes included), not parsed.
        case bookmark(url: String)
        case folder(children: [BookmarkNode])
    }

    public var title: String
    public var kind: Kind
    public var dateAdded: Date?
    /// Folders only: when the folder's contents last changed.
    public var dateModified: Date?
    /// Bookmarks only: when it was last opened, where Brave recorded it.
    public var dateLastUsed: Date?
    /// Brave's GUID for the node, when present. Useful to avoid importing the same item twice.
    public var guid: String?

    public init(title: String, kind: Kind, dateAdded: Date? = nil, dateModified: Date? = nil,
                dateLastUsed: Date? = nil, guid: String? = nil) {
        self.title = title
        self.kind = kind
        self.dateAdded = dateAdded
        self.dateModified = dateModified
        self.dateLastUsed = dateLastUsed
        self.guid = guid
    }

    public var url: String? {
        if case .bookmark(let url) = kind { return url }
        return nil
    }

    public var children: [BookmarkNode] {
        if case .folder(let children) = kind { return children }
        return []
    }

    public var isFolder: Bool {
        if case .folder = kind { return true }
        return false
    }

    /// Bookmarks (not folders) in this node and below.
    public var bookmarkCount: Int {
        switch kind {
        case .bookmark: return 1
        case .folder(let children): return children.reduce(0) { $0 + $1.bookmarkCount }
        }
    }

    /// Folders below this node, not counting the node itself.
    public var folderCount: Int {
        children.reduce(0) { $0 + ($1.isFolder ? 1 + $1.folderCount : 0) }
    }
}

/// A profile's bookmarks: one folder per Brave root ("Bookmarks bar", "Other bookmarks",
/// "Mobile bookmarks"), each keeping its own title.
public struct BraveBookmarks: Equatable, Sendable {
    public enum Root: Equatable, Sendable {
        case bookmarkBar, other, mobile
        /// A root this reader doesn't know by name, keyed as in the file.
        case unknown(String)
    }

    public struct Entry: Equatable, Sendable {
        public var root: Root
        /// The root folder, with Brave's title for it.
        public var folder: BookmarkNode

        public init(root: Root, folder: BookmarkNode) {
            self.root = root
            self.folder = folder
        }
    }

    public var roots: [Entry]

    public init(roots: [Entry]) {
        self.roots = roots
    }

    public var bookmarkCount: Int { roots.reduce(0) { $0 + $1.folder.bookmarkCount } }
    /// Folders inside the roots (the roots themselves are not counted).
    public var folderCount: Int { roots.reduce(0) { $0 + $1.folder.folderCount } }
}

public enum BookmarksError: Error, Equatable {
    /// The file isn't JSON, or has no `roots` object.
    case malformed(String)
}

public enum BookmarksReader {
    /// Reads a profile's `Bookmarks` file. A profile without one has no bookmarks; one that can't
    /// be read throws (`BraveAccessError.permissionDenied` when macOS refuses), never "empty".
    public static func read(profile: BraveProfile) throws -> BraveBookmarks {
        guard let data = try BraveFiles.readIfPresent(profile.bookmarksURL) else { return BraveBookmarks(roots: []) }
        return try parse(data)
    }

    public static func read(contentsOf url: URL) throws -> BraveBookmarks {
        try parse(BraveFiles.read(url))
    }

    /// Parses Chromium's bookmarks JSON:
    /// `{"roots": {"bookmark_bar": node, "other": node, "synced": node}, "version": 1, ...}`,
    /// where a node is `{"type": "folder"|"url", "name", "url", "children", "date_added",
    /// "date_modified", "date_last_used", "guid", ...}` and dates are microsecond strings.
    /// Nodes of an unknown type are skipped; a node with no usable shape is skipped, not fatal.
    public static func parse(_ data: Data) throws -> BraveBookmarks {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw BookmarksError.malformed("not JSON: \(error.localizedDescription)")
        }
        guard let top = json as? [String: Any], let roots = top["roots"] as? [String: Any] else {
            throw BookmarksError.malformed("no roots object")
        }
        let known: [(String, BraveBookmarks.Root)] = [("bookmark_bar", .bookmarkBar), ("other", .other),
                                                      ("synced", .mobile)]
        var result: [BraveBookmarks.Entry] = []
        for (key, root) in known {
            if let node = roots[key] as? [String: Any], let folder = parseNode(node), folder.isFolder {
                result.append(.init(root: root, folder: folder))
            }
        }
        // Anything else that looks like a folder root (newer Chromium versions add roots). The
        // `sync_transaction_version` style entries are strings or numbers and are skipped.
        for key in roots.keys.sorted() where !known.contains(where: { $0.0 == key }) {
            if let node = roots[key] as? [String: Any], let folder = parseNode(node), folder.isFolder {
                result.append(.init(root: .unknown(key), folder: folder))
            }
        }
        return BraveBookmarks(roots: result)
    }

    private static func parseNode(_ node: [String: Any]) -> BookmarkNode? {
        let title = node["name"] as? String ?? ""
        let guid = node["guid"] as? String
        let added = ChromiumTime.date(string: node["date_added"] as? String)
        switch node["type"] as? String {
        case "url":
            guard let url = node["url"] as? String else { return nil }
            return BookmarkNode(title: title, kind: .bookmark(url: url), dateAdded: added,
                                dateLastUsed: ChromiumTime.date(string: node["date_last_used"] as? String),
                                guid: guid)
        case "folder":
            let children = (node["children"] as? [Any] ?? []).compactMap { child -> BookmarkNode? in
                guard let dict = child as? [String: Any] else { return nil }
                return parseNode(dict)
            }
            return BookmarkNode(title: title, kind: .folder(children: children), dateAdded: added,
                                dateModified: ChromiumTime.date(string: node["date_modified"] as? String),
                                guid: guid)
        default:
            return nil
        }
    }
}
