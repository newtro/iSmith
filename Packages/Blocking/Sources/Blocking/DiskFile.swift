import CryptoKit
import Foundation

/// Small file helpers: atomic writes (a crash never leaves half a file), backups of unreadable
/// files, and content digests.
enum DiskFile {
    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Copies an unreadable file aside so it can be recovered. Nothing is written over an
    /// existing copy.
    @discardableResult
    static func backUp(_ url: URL, reason: String) throws -> URL {
        let stamp = Int(Date().timeIntervalSince1970)
        let base = url.deletingPathExtension()
        var backup = base.appendingPathExtension("\(reason)-\(stamp).\(url.pathExtension)")
        var n = 2
        while FileManager.default.fileExists(atPath: backup.path) {
            backup = base.appendingPathExtension("\(reason)-\(stamp)-\(n).\(url.pathExtension)")
            n += 1
        }
        try FileManager.default.copyItem(at: url, to: backup)
        return backup
    }

    static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
