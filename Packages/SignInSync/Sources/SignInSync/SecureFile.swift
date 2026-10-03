import Foundation

/// Owner-only files for config and the vault: folders are 0700, files 0600 from the moment they
/// exist, and a write replaces the old file in one step so a crash never leaves half a file.
enum SecureFile {
    /// Creates the folder if needed and limits it to the owner.
    static func prepareDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    static func write(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(code)
        }
    }

    /// Copies an unreadable file aside so it can be recovered, and returns the copy's location.
    /// Nothing is written over an existing copy.
    static func backUp(_ url: URL, reason: String) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        var backup = url.deletingPathExtension().appendingPathExtension("\(reason)-\(stamp).\(url.pathExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = url.deletingPathExtension().appendingPathExtension("\(reason)-\(stamp)-\(n).\(url.pathExtension)")
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }
}
