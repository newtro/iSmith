import Foundation

/// Owner-only files for the password database, as SignInSync does for the vault: the folder is
/// 0700 and the database 0600 from the moment it exists. SQLite gives its side files (`-journal`,
/// `-wal`, `-shm`) the database's mode, so they're owner-only too; `limitSideFilesToOwner` makes
/// sure of it.
enum SecureFile {
    static func prepareDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// Creates an empty 0600 file if none exists, and limits an existing one to the owner.
    static func ensureOwnerOnlyFile(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        if fd >= 0 {
            close(fd)
        } else if errno != EEXIST {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// SQLite's side files for a database.
    static func sideFiles(of url: URL) -> [URL] {
        ["-journal", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
    }

    /// Limits the side files that exist to the owner.
    static func limitSideFilesToOwner(of url: URL) throws {
        for side in sideFiles(of: url) where FileManager.default.fileExists(atPath: side.path) {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: side.path)
        }
    }

    /// The file's inode, to tell whether a path still names the same file.
    static func inode(of url: URL) -> UInt64? {
        var info = stat()
        return stat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    /// A move aside that failed part way and couldn't be fully put back.
    struct IncompleteMove: Error, CustomStringConvertible {
        /// Where each file is now (paths only).
        var locations: [(file: String, now: String)]
        var cause: String
        var description: String {
            "\(cause). Where each file is now: " + locations.map { "\($0.file) is at \($0.now)" }.joined(separator: "; ")
        }
    }

    /// Moves a database that can't be opened, with its side files, aside so it can be recovered
    /// later, and returns where it went. Nothing is overwritten or deleted. Call it only with
    /// the store's lock held exclusively (no other connection has the file open).
    ///
    /// The `-wal` (logins not yet checkpointed into the main file) and `-journal` move with it:
    /// left behind, they'd be lost to the copy and could be replayed into the new file. If one
    /// can't be moved, everything is put back and the move throws; if putting back fails too, it
    /// throws `IncompleteMove`, saying where each file is. The `-shm` is only an index SQLite
    /// rebuilds; it moves too when it can.
    ///
    /// Not crash-atomic: the files move one rename at a time, so a crash between renames leaves
    /// the main file at the new name and its `-wal` at the old one (nothing is lost, but nothing
    /// reconciles it at the next launch yet).
    static func moveAside(_ url: URL, reason: String, mover: (URL, URL) throws -> Void = { try FileManager.default.moveItem(at: $0, to: $1) }) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        var target = base.appendingPathExtension("\(reason)-\(stamp).\(ext)")
        var n = 2
        func taken(_ candidate: URL) -> Bool {
            ([candidate] + sideFiles(of: candidate)).contains { FileManager.default.fileExists(atPath: $0.path) }
        }
        while taken(target) {
            target = base.appendingPathExtension("\(reason)-\(stamp)-\(n).\(ext)")
            n += 1
        }
        let fm = FileManager.default
        try mover(url, target)
        var moved: [(from: URL, to: URL)] = [(url, target)]
        for (side, newSide) in zip(sideFiles(of: url), sideFiles(of: target)) where fm.fileExists(atPath: side.path) {
            do {
                try mover(side, newSide)
                moved.append((side, newSide))
            } catch where side.path.hasSuffix("-shm") {
                continue
            } catch {
                var stuck: [(file: String, now: String)] = []
                for item in moved.reversed() {
                    do {
                        try mover(item.to, item.from)
                    } catch {
                        stuck.append((item.from.lastPathComponent, item.to.path))
                    }
                }
                guard stuck.isEmpty else {
                    var locations = stuck
                    locations.append((side.lastPathComponent, side.path))
                    throw IncompleteMove(locations: locations, cause: "\(side.lastPathComponent) couldn't be moved (\(type(of: error)))")
                }
                throw error
            }
        }
        return target
    }
}
