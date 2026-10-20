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

    /// Moves a database that can't be opened, with its side files, aside so it can be recovered
    /// later, and returns where it went. Nothing is overwritten or deleted.
    ///
    /// The `-wal` (logins not yet checkpointed into the main file) and `-journal` move with it:
    /// left behind, they'd be lost to the copy and could be replayed into the new file. If one
    /// can't be moved, everything is put back and the move throws. The `-shm` is only an index
    /// SQLite rebuilds; it moves too when it can.
    static func moveAside(_ url: URL, reason: String) throws -> URL {
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
        try fm.moveItem(at: url, to: target)
        var moved: [(from: URL, to: URL)] = [(url, target)]
        for (side, newSide) in zip(sideFiles(of: url), sideFiles(of: target)) where fm.fileExists(atPath: side.path) {
            do {
                try fm.moveItem(at: side, to: newSide)
                moved.append((side, newSide))
            } catch where side.path.hasSuffix("-shm") {
                continue
            } catch {
                for item in moved.reversed() { try? fm.moveItem(at: item.to, to: item.from) }
                throw error
            }
        }
        return target
    }
}
