import Foundation
import GRDB

/// The "v3-global-bookmarks" migration (2026-10-06): bookmarks were one tree per space and become
/// one tree shared by every space. The per-space copies are merged, then the `space` column goes.
///
/// The merge rule:
///
/// - Spaces are taken in order: most bookmarks and folders first (roots not counted), ties by
///   space id. The first is the primary space; its tree is kept as it is, ids, order and all.
/// - Each other space's tree is then folded in, root by root (its Bookmarks Bar into the
///   Bookmarks Bar, its Other Bookmarks into Other Bookmarks), folder by folder, in order:
///   - a folder whose external id (Brave's GUID) is already in the merged tree, as a folder, is
///     that folder, wherever it is (a rename made only in this space is not kept); a bookmark
///     with an external id already there is that bookmark only if its title and URL are the same
///     too, so a bookmark edited in one space keeps both versions;
///   - otherwise an item in the same folder with the same title (and, for bookmarks, the same
///     URL) is that item, unless both have external ids and they differ. Each item there is
///     matched at most once per folder, so two identical bookmarks in one folder stay two;
///   - a matched folder has the space's contents of that folder folded into it the same way;
///   - anything unmatched is added at the end of the folder it was in (that folder being the
///     merged one), keeping its order relative to the other added items, with its contents.
/// - The roots left over from the other spaces go. Every folder's positions are made dense.
///
/// So three identical copies (the same Brave import into three spaces) become one copy, and a
/// bookmark found in only one space is never lost. It is a union: a bookmark deleted in one
/// space but still in another comes back. The file is backed up before this runs, and it all
/// runs in the migration's transaction.
enum BookmarkMerge {
    private struct Node {
        let id: Int64
        let space: String
        let parentID: Int64?
        let isFolder: Bool
        let title: String
        let url: String?
        let position: Int
        let externalID: String?
        let root: BookmarkRoot?
    }

    static func migrate(_ db: Database) throws {
        let nodes = try Row.fetchAll(db, sql: """
            SELECT id, space, parentID, isFolder, title, url, position, externalID, root FROM bookmark ORDER BY id
            """).map { row in
            Node(id: row["id"], space: row["space"], parentID: row["parentID"], isFolder: row["isFolder"],
                 title: row["title"], url: row["url"], position: row["position"], externalID: row["externalID"],
                 root: (row["root"] as String?).flatMap(BookmarkRoot.init(rawValue:)))
        }
        if !nodes.isEmpty { try merge(db, nodes) }
        try db.execute(sql: """
            DROP INDEX bookmark_root;
            DROP INDEX bookmark_space_url;
            DROP INDEX bookmark_space_externalID;
            ALTER TABLE bookmark DROP COLUMN space;
            CREATE UNIQUE INDEX bookmark_root ON bookmark(root) WHERE root IS NOT NULL;
            CREATE INDEX bookmark_url ON bookmark(url);
            CREATE INDEX bookmark_externalID ON bookmark(externalID) WHERE externalID IS NOT NULL;
            """)
    }

    private static func merge(_ db: Database, _ nodes: [Node]) throws {
        let byID = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

        // Each space's tree as it was: children in order, roots by kind. A row whose parent is
        // missing (none should be) goes at the end of its space's Other Bookmarks, else its Bar,
        // else (a space without roots) at the end of the merged Other Bookmarks.
        var children: [Int64: [Node]] = [:]
        var roots: [String: [BookmarkRoot: Node]] = [:]
        var orphans: [Node] = []
        for node in nodes {
            if let root = node.root, node.parentID == nil {
                roots[node.space, default: [:]][root] = node
            } else if let parent = node.parentID, byID[parent] != nil {
                children[parent, default: []].append(node)
            } else {
                orphans.append(node)
            }
        }
        for key in children.keys { children[key]!.sort { ($0.position, $0.id) < ($1.position, $1.id) } }
        var homeless: [Node] = []
        for orphan in orphans {
            guard let home = roots[orphan.space]?[.other] ?? roots[orphan.space]?[.bar] else {
                homeless.append(orphan)
                continue
            }
            children[home.id, default: []].append(orphan)
        }

        // Spaces in merge order: most items first, ties by space id.
        var counts: [String: Int] = [:]
        for node in nodes where node.root == nil { counts[node.space, default: 0] += 1 }
        let spaces = Set(nodes.map(\.space)).sorted { a, b in
            let (ca, cb) = (counts[a] ?? 0, counts[b] ?? 0)
            return ca != cb ? ca > cb : a < b
        }

        // The merged tree, as row ids.
        var merged: [Int64: [Int64]] = [:]
        var mergedRoots: [BookmarkRoot: Int64] = [:]
        var byExternalID: [String: Int64] = [:]

        /// `primary`: the first space's tree, kept exactly as it is (nothing in it is matched).
        func fold(_ source: Int64, into target: Int64, primary: Bool) {
            var matched = Set<Int64>()
            for item in children[source] ?? [] {
                var match: Int64?
                if primary {
                    match = nil
                } else if let ext = item.externalID, let found = byExternalID[ext], !matched.contains(found),
                          let other = byID[found], other.isFolder == item.isFolder,
                          item.isFolder || (other.title == item.title && other.url == item.url) {
                    match = found
                } else {
                    match = merged[target, default: []].first { id in
                        guard !matched.contains(id), let other = byID[id] else { return false }
                        if let a = item.externalID, let b = other.externalID, a != b { return false }
                        return other.isFolder == item.isFolder && other.title == item.title && other.url == item.url
                    }
                }
                if let match {
                    matched.insert(match)
                    if let ext = item.externalID, byExternalID[ext] == nil { byExternalID[ext] = match }
                    if item.isFolder { fold(item.id, into: match, primary: false) }
                } else {
                    merged[target, default: []].append(item.id)
                    matched.insert(item.id)
                    if let ext = item.externalID, byExternalID[ext] == nil { byExternalID[ext] = item.id }
                    if item.isFolder {
                        merged[item.id] = []
                        fold(item.id, into: item.id, primary: primary)
                    }
                }
            }
        }

        for (index, space) in spaces.enumerated() {
            for kind in BookmarkRoot.allCases {
                guard let root = roots[space]?[kind] else { continue }
                if mergedRoots[kind] == nil {
                    mergedRoots[kind] = root.id
                    merged[root.id] = []
                }
                fold(root.id, into: mergedRoots[kind]!, primary: index == 0)
            }
        }
        if !homeless.isEmpty {
            if mergedRoots[.other] == nil {
                let root = BookmarkRoot.other
                try db.execute(sql: """
                    INSERT INTO bookmark (space, parentID, isFolder, title, url, search, position, dateAdded, root)
                    VALUES (?, NULL, 1, ?, NULL, ?, 1, ?, ?)
                    """, arguments: [spaces[0], root.title, root.title.lowercased() + "\n",
                                     Date().timeIntervalSince1970, root.rawValue])
                mergedRoots[.other] = db.lastInsertedRowID
                merged[db.lastInsertedRowID] = []
            }
            let source = Int64.min  // no row has this id
            children[source] = homeless
            fold(source, into: mergedRoots[.other]!, primary: false)
        }

        // Write it: parents and dense positions for what's kept, then remove the rest.
        var kept = Set<Int64>()
        for (kind, id) in mergedRoots {
            kept.insert(id)
            try db.execute(sql: "UPDATE bookmark SET parentID = NULL, position = ? WHERE id = ?",
                           arguments: [kind == .bar ? 0 : 1, id])
        }
        for (parent, items) in merged {
            for (position, id) in items.enumerated() {
                kept.insert(id)
                try db.execute(sql: "UPDATE bookmark SET parentID = ?, position = ? WHERE id = ?",
                               arguments: [parent, position, id])
            }
        }
        for node in nodes where !kept.contains(node.id) {
            try db.execute(sql: "DELETE FROM bookmark WHERE id = ?", arguments: [node.id])
        }
    }
}
