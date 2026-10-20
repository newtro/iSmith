import Foundation

/// One pairing in progress on the Mac (PROTOCOL.md §2). It holds the fresh Mac key pair and the
/// pairing secret `S`, which only ever leave in the QR code, and the Mac token the relay issued.
public struct PairingSession: Sendable {
    public let relayURL: URL
    public let pairingID: String
    public let registrationToken: String
    /// The bearer token for this Mac (b64u, as the relay sent it).
    public let macToken: String
    public let expiresAt: Date
    public let macName: String
    public let keyPair: BoxKeyPair
    /// `S`: 32 random bytes; never sent to the relay.
    public let secret: Data

    public init(relayURL: URL, reply: PairStartReply, macName: String,
                keyPair: BoxKeyPair = .generate(), secret: Data = BoxCrypto.randomBytes(32)) {
        self.relayURL = relayURL
        pairingID = reply.pairingId
        registrationToken = reply.registrationToken
        macToken = reply.macToken
        expiresAt = Date(timeIntervalSince1970: TimeInterval(reply.expiresAt) / 1000)
        self.macName = macName
        self.keyPair = keyPair
        self.secret = secret
    }

    /// `2fasync://pair?v=1&u=<relay>&p=<pairingId>&t=<token>&k=<macPub>&s=<S>&n=<macName>`.
    public var qrURI: String {
        let items: [(String, String)] = [
            ("v", "1"),
            ("u", Self.percentEncode(Self.baseString(relayURL))),
            ("p", pairingID),
            ("t", registrationToken),
            ("k", Base64URL.encode(keyPair.publicKey)),
            ("s", Base64URL.encode(secret)),
            ("n", Self.percentEncode(macName)),
        ]
        return "2fasync://pair?" + items.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    /// What the phone sent back through the relay, checked against `S`.
    public enum Verdict: Equatable {
        /// The proof matches: show this fingerprint.
        case verified(phonePublicKey: Data, phoneName: String, fingerprint: String)
        /// The key or proof was missing, malformed or didn't match: the relay (or anyone) swapped it.
        case rejected
    }

    public func check(_ status: PairStatusReply) -> Verdict {
        guard let pub = status.phonePublicKey.flatMap(Base64URL.decode), pub.count == BoxCrypto.keyBytes,
              let proof = status.proof.flatMap(Base64URL.decode), proof.count == 32
        else { return .rejected }
        guard BoxCrypto.proofMatches(proof, secret: secret, pairingID: pairingID,
                                     macPublicKey: keyPair.publicKey, phonePublicKey: pub)
        else { return .rejected }
        let name = Self.cleanName(status.phoneName)
        return .verified(phonePublicKey: pub, phoneName: name,
                         fingerprint: BoxCrypto.fingerprint(macPublicKey: keyPair.publicKey, phonePublicKey: pub))
    }

    /// A phone name fit to show: printable, trimmed, at most 64 characters.
    static func cleanName(_ name: String?) -> String {
        let printable = (name ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
        let trimmed = String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Phone" : String(trimmed.prefix(64))
    }

    /// The relay base URL without a trailing slash.
    static func baseString(_ url: URL) -> String {
        var s = url.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// RFC 3986 unreserved characters stay; everything else is %XX (UTF-8).
    static func percentEncode(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
