import Foundation

/// Owner-only files for the browser database, as the password store does: the folder is 0700 and
/// the database 0600 from the moment it exists. SQLite gives its WAL and shared-memory files the
/// database's mode, so they are owner-only too.
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

    /// Creates a new, empty 0600 file; throws if something is already there.
    static func createOwnerOnlyFile(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        close(fd)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// SQLite's side files for a database.
    static func sideFiles(of url: URL) -> [URL] {
        ["-journal", "-wal", "-shm"].map { URL(fileURLWithPath: url.path + $0) }
    }

    /// A free name next to `url`: `browser.<tag>-<time>.sqlite`, then `…-<time>-2.sqlite` and on.
    static func unusedSibling(of url: URL, tag: String) -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        var target = base.appendingPathExtension("\(tag)-\(stamp).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) {
            target = base.appendingPathExtension("\(tag)-\(stamp)-\(n).\(ext)")
            n += 1
        }
        return target
    }

    /// Moves a database that can't be opened (and its side files) aside, so it can be recovered
    /// later, and returns where it went. Nothing is overwritten.
    static func moveAside(_ url: URL, reason: String) throws -> URL {
        let target = unusedSibling(of: url, tag: reason)
        try FileManager.default.moveItem(at: url, to: target)
        for (side, newSide) in zip(sideFiles(of: url), sideFiles(of: target))
        where FileManager.default.fileExists(atPath: side.path) {
            try? FileManager.default.moveItem(at: side, to: newSide)
        }
        return target
    }
}
