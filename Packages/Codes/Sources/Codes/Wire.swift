import Foundation

/// base64url without padding (RFC 4648 §5), the encoding of every binary value on the wire.
public enum Base64URL {
    public static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func encode(_ bytes: [UInt8]) -> String { encode(Data(bytes)) }

    /// nil for anything that isn't strict unpadded base64url.
    public static func decode(_ string: String) -> Data? {
        guard string.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        guard string.count % 4 != 1 else { return nil }
        var s = string.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s.append("=") }
        return Data(base64Encoded: s)
    }
}

/// What the relay sees of a message: `{"v":1,"id":"…","nonce":"<b64u 24 bytes>","ct":"<b64u>"}`.
public struct Envelope: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var nonce: String
    public var ct: String

    public init(v: Int = 1, id: String, nonce: String, ct: String) {
        self.v = v
        self.id = id
        self.nonce = nonce
        self.ct = ct
    }

    /// The largest ciphertext a v1 envelope may carry (decoded).
    public static let maxCiphertext = 4096
}

/// The sealed plaintext (PROTOCOL.md §3). Unknown fields are ignored.
public struct CodeMessage: Codable, Equatable, Sendable {
    public var v: Int
    public var id: String
    public var ctr: Int64
    /// When the SMS arrived on the phone (Unix ms).
    public var ts: Int64
    public var sender: String
    public var code: String
    public var domain: String?
    public var body: String
    /// Set by the receiver when the message named a WebOTP domain the Mac couldn't use: the code
    /// is bound to no host at all (never offered on a page). Not part of the wire format.
    public internal(set) var bindingUnusable = false

    public init(v: Int = 1, id: String, ctr: Int64, ts: Int64, sender: String, code: String, domain: String?, body: String) {
        self.v = v
        self.id = id
        self.ctr = ctr
        self.ts = ts
        self.sender = sender
        self.code = code
        self.domain = domain
        self.body = body
    }

    private enum CodingKeys: String, CodingKey { case v, id, ctr, ts, sender, code, domain, body }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decode(Int.self, forKey: .v)
        id = try c.decode(String.self, forKey: .id)
        ctr = try c.decode(Int64.self, forKey: .ctr)
        ts = try c.decode(Int64.self, forKey: .ts)
        sender = try c.decode(String.self, forKey: .sender)
        code = try c.decode(String.self, forKey: .code)
        domain = try c.decodeIfPresent(String.self, forKey: .domain)
        body = try c.decode(String.self, forKey: .body)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(id, forKey: .id)
        try c.encode(ctr, forKey: .ctr)
        try c.encode(ts, forKey: .ts)
        try c.encode(sender, forKey: .sender)
        try c.encode(code, forKey: .code)
        try c.encode(domain, forKey: .domain) // null, not missing
        try c.encode(body, forKey: .body)
    }

    /// The field rules of §3 that the receiver enforces (lengths and character sets).
    var isWellFormed: Bool {
        guard v == 1, Self.isLowercaseUUID(id), ctr >= 1, ts > 0 else { return false }
        guard !sender.isEmpty, sender.count <= 64 else { return false }
        guard (4...10).contains(code.count),
              code.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "-") })
        else { return false }
        return true
    }

    /// The message with its WebOTP domain normalized (lowercased, one trailing dot removed).
    /// A domain that still isn't a plain multi-label ASCII host (an IDN the phone didn't punycode,
    /// an underscore, a single label) fails closed: the code is kept for the notification, but
    /// `bindingUnusable` is set and it's never offered in iSmith.
    func withCheckedDomain() -> CodeMessage {
        guard let raw = domain else { return self }
        var copy = self
        if let normal = Hostname.normalize(raw), normal.contains(".") {
            copy.domain = normal
        } else {
            copy.domain = nil
            copy.bindingUnusable = true
        }
        return copy
    }

    static func isLowercaseUUID(_ s: String) -> Bool {
        s.count == 36 && s == s.lowercased() && UUID(uuidString: s) != nil
    }
}

/// A frame the relay sends on the stream.
enum StreamFrame: Decodable {
    case message(Envelope, receivedAt: Int64?)
    case revoked
    case other(String)

    private enum Keys: String, CodingKey { case type, envelope, receivedAt }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "message":
            self = .message(try c.decode(Envelope.self, forKey: .envelope),
                            receivedAt: try c.decodeIfPresent(Int64.self, forKey: .receivedAt))
        case "revoked":
            self = .revoked
        default:
            self = .other(type)
        }
    }
}

// MARK: - Relay HTTP bodies

public struct PairStartReply: Codable, Equatable, Sendable {
    public var pairingId: String
    public var registrationToken: String
    public var macToken: String
    public var expiresAt: Int64

    public init(pairingId: String, registrationToken: String, macToken: String, expiresAt: Int64) {
        self.pairingId = pairingId
        self.registrationToken = registrationToken
        self.macToken = macToken
        self.expiresAt = expiresAt
    }
}

/// `GET /v1/pair` as the Mac sees it.
public struct PairStatusReply: Codable, Equatable, Sendable {
    public var state: String
    public var phonePublicKey: String?
    public var phoneName: String?
    public var proof: String?

    public init(state: String, phonePublicKey: String?, phoneName: String?, proof: String?) {
        self.state = state
        self.phonePublicKey = phonePublicKey
        self.phoneName = phoneName
        self.proof = proof
    }
}

/// Host names as the WebOTP binding compares them.
public enum Hostname {
    /// Lowercased, one trailing dot removed, and only when the result is a plain ASCII host name:
    /// labels of 1–63 letters, digits and inner hyphens, at most 253 characters. nil otherwise
    /// (empty, non-ASCII, `/`, `:`, `#`, spaces, `_`, empty labels, a leading dot).
    public static func normalize(_ host: String) -> String? {
        var h = host.lowercased()
        if h.hasSuffix(".") { h.removeLast() }
        guard !h.isEmpty, h.count <= 253 else { return nil }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        for label in labels {
            guard (1...63).contains(label.count), !label.hasPrefix("-"), !label.hasSuffix("-"),
                  label.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
            else { return nil }
        }
        return h
    }
}
