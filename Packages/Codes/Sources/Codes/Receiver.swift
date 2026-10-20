import Foundation

/// Owner-only files for the agent's small state (the seen set, the pairing record, settings).
enum OwnerOnlyFile {
    static func prepareDirectory(_ dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
    }

    /// Writes atomically, then makes the file 0600. The directory is 0700, so the temporary copy
    /// is never readable by anyone else either.
    static func write(_ data: Data, to url: URL) throws {
        try prepareDirectory(url.deletingLastPathComponent())
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// The `(id, ctr)` pairs already accepted, kept on disk for at least 15 minutes so a replay after
/// an agent restart is still caught (PROTOCOL.md §3). Scoped to one pairing: a new pairing's
/// counter starts at 1 again.
public final class SeenStore {
    struct Entry: Codable, Equatable {
        var id: String
        var ctr: Int64
        /// When it was accepted (Unix ms).
        var at: Int64
    }

    struct File: Codable {
        var pairingID: String
        var entries: [Entry]
    }

    /// Entries are kept this long (longer than the 15 minutes §3 asks, and the 12-minute window
    /// a `ts` can be accepted in).
    static let keep: TimeInterval = 20 * 60

    public let fileURL: URL?
    private(set) var pairingID: String
    private(set) var entries: [Entry] = []

    /// `fileURL` nil keeps the set in memory only (tests).
    public init(fileURL: URL?, pairingID: String) {
        self.fileURL = fileURL
        self.pairingID = pairingID
        if let fileURL, let data = try? Data(contentsOf: fileURL),
           let file = try? JSONDecoder().decode(File.self, from: data), file.pairingID == pairingID {
            entries = file.entries
        }
    }

    public func contains(id: String, ctr: Int64) -> Bool {
        entries.contains { $0.id == id || $0.ctr == ctr }
    }

    public func insert(id: String, ctr: Int64, now: Date) {
        prune(now: now)
        entries.append(Entry(id: id, ctr: ctr, at: Int64(now.timeIntervalSince1970 * 1000)))
        save()
    }

    func prune(now: Date) {
        let cutoff = Int64((now.timeIntervalSince1970 - Self.keep) * 1000)
        entries.removeAll { $0.at < cutoff }
    }

    private func save() {
        guard let fileURL else { return }
        do {
            try OwnerOnlyFile.write(JSONEncoder().encode(File(pairingID: pairingID, entries: entries)), to: fileURL)
        } catch {
            codesLog.error("seen set not saved: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The Mac's receiver rules (PROTOCOL.md §3). Every envelope gets a verdict; both kinds are
/// acked so the relay forgets them.
public struct Receiver {
    public enum Drop: String, Equatable, Sendable {
        case malformedEnvelope = "malformed envelope"
        case boxDidNotOpen = "box did not open"
        case badPlaintext = "plaintext is not valid v1"
        case idMismatch = "inner id differs from the envelope id"
        case stale = "ts more than 10 minutes in the past"
        case future = "ts more than 2 minutes in the future"
        case replay = "id or ctr seen before"
    }

    public enum Verdict: Equatable {
        case accepted(CodeMessage)
        case dropped(Drop)
    }

    public static let maxAge: TimeInterval = 10 * 60
    public static let maxSkew: TimeInterval = 2 * 60

    public let phonePublicKey: Data
    public let macSecretKey: Data
    public let seen: SeenStore

    public init(phonePublicKey: Data, macSecretKey: Data, seen: SeenStore) {
        self.phonePublicKey = phonePublicKey
        self.macSecretKey = macSecretKey
        self.seen = seen
    }

    /// Opens and checks one envelope. An accepted message's `(id, ctr)` is recorded before this
    /// returns, so it can't be accepted twice.
    public func receive(_ envelope: Envelope, now: Date = Date()) -> Verdict {
        guard envelope.v == 1, let nonce = Base64URL.decode(envelope.nonce), nonce.count == BoxCrypto.nonceBytes,
              let ct = Base64URL.decode(envelope.ct), ct.count <= Envelope.maxCiphertext
        else { return .dropped(.malformedEnvelope) }
        guard let plain = BoxCrypto.open(ciphertext: ct, nonce: nonce, senderPublicKey: phonePublicKey,
                                         recipientSecretKey: macSecretKey)
        else { return .dropped(.boxDidNotOpen) }
        guard let message = try? JSONDecoder().decode(CodeMessage.self, from: plain), message.isWellFormed
        else { return .dropped(.badPlaintext) }
        guard message.id == envelope.id else { return .dropped(.idMismatch) }
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        if message.ts < nowMs - Int64(Self.maxAge * 1000) { return .dropped(.stale) }
        if message.ts > nowMs + Int64(Self.maxSkew * 1000) { return .dropped(.future) }
        seen.prune(now: now)
        if seen.contains(id: message.id, ctr: message.ctr) { return .dropped(.replay) }
        seen.insert(id: message.id, ctr: message.ctr, now: now)
        return .accepted(message)
    }
}
