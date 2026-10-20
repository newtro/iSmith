import Codes
import Foundation

/// The Android app's side of the protocol, enough to pair with a Mac and send it codes: reads
/// the QR URI, proves its key with `S`, seals messages to the Mac's key.
public final class FakePhone: @unchecked Sendable {
    /// The phone the FakeRelay executable's test hooks drive.
    nonisolated(unsafe) static var shared: FakePhone?

    public let name: String
    public let keyPair: BoxKeyPair
    public private(set) var macPublicKey = Data()
    public private(set) var pairingID = ""
    public private(set) var phoneToken = ""
    public private(set) var relay: URL?
    private var counter: Int64 = 0
    private let session = URLSession(configuration: .ephemeral)

    public init(name: String = "Galaxy S24", keyPair: BoxKeyPair = .generate()) {
        self.name = name
        self.keyPair = keyPair
    }

    public struct URIParts {
        public var relay: URL
        public var pairingID: String
        public var registrationToken: String
        public var macPublicKey: Data
        public var secret: Data
        public var macName: String
    }

    /// Parses a `2fasync://pair?…` URI as the phone does (v=1, 32-byte k, t and s, a UUID p).
    /// `allowHTTP` lets the fake relay's plain-http URL through.
    public static func parse(_ uri: String, allowHTTP: Bool = true) -> URIParts? {
        // "2fasync" starts with a digit, which RFC 3986 doesn't allow in a scheme, so Foundation's
        // URL parsers refuse the whole URI (Android's Uri is lenient). Split it by hand.
        let prefix = "2fasync://pair?"
        guard uri.hasPrefix(prefix), let parts = URLComponents(string: "x://pair?" + uri.dropFirst(prefix.count)) else { return nil }
        var q: [String: String] = [:]
        for item in parts.queryItems ?? [] { q[item.name] = item.value }
        guard q["v"] == "1", let u = q["u"], let relay = URL(string: u),
              relay.scheme == "https" || (allowHTTP && relay.scheme == "http"),
              let p = q["p"], UUID(uuidString: p) != nil,
              let t = q["t"], Base64URL.decode(t)?.count == 32,
              let k = q["k"].flatMap(Base64URL.decode), k.count == 32,
              let s = q["s"].flatMap(Base64URL.decode), s.count == 32
        else { return nil }
        return URIParts(relay: relay, pairingID: p, registrationToken: t, macPublicKey: k, secret: s, macName: q["n"] ?? "")
    }

    /// `POST /v1/pair/complete` with the proof. `relay` overrides the URI's relay URL.
    public func pair(uri: String, relay override: URL? = nil, proofKey: Data? = nil) async throws {
        guard let parts = Self.parse(uri) else { throw RelayError.badReply }
        let relay = override ?? parts.relay
        self.relay = relay
        macPublicKey = parts.macPublicKey
        pairingID = parts.pairingID
        let proof = BoxCrypto.pairingProof(secret: parts.secret, pairingID: parts.pairingID,
                                           macPublicKey: parts.macPublicKey, phonePublicKey: proofKey ?? keyPair.publicKey)
        let body: [String: Any] = ["pairingId": parts.pairingID, "registrationToken": parts.registrationToken,
                                   "phonePublicKey": Base64URL.encode(keyPair.publicKey), "phoneName": name,
                                   "proof": Base64URL.encode(proof)]
        let reply = try await post(relay.appendingPathComponent("v1/pair/complete"), body, token: nil)
        guard let token = reply["phoneToken"] as? String else { throw RelayError.badReply }
        phoneToken = token
    }

    /// A sealed envelope for a code; every field can be bent for the receiver tests.
    public func envelope(code: String = "123456", domain: String? = nil, sender: String = "72975",
                         body: String? = nil, id: String = UUID().uuidString.lowercased(), innerID: String? = nil,
                         ctr: Int64? = nil, ts: Date = Date(), to macPublicKey: Data? = nil) -> [String: Any] {
        let ctr = ctr ?? { counter += 1; return counter }()
        let message = CodeMessage(id: innerID ?? id, ctr: ctr, ts: Int64(ts.timeIntervalSince1970 * 1000), sender: sender,
                                  code: code, domain: domain,
                                  body: body ?? "\(code) is your verification code." + (domain.map { "\n\n@\($0) #\(code)" } ?? ""))
        let plain = try! JSONEncoder().encode(message)
        let nonce = BoxCrypto.randomBytes(BoxCrypto.nonceBytes)
        let ct = BoxCrypto.seal(plain, nonce: nonce, recipientPublicKey: macPublicKey ?? self.macPublicKey,
                                senderSecretKey: keyPair.secretKey)!
        return ["v": 1, "id": id, "nonce": Base64URL.encode(nonce), "ct": Base64URL.encode(ct)]
    }

    /// `POST /v1/messages`. Returns the envelope's id.
    public func send(code: String, domain: String? = nil, sender: String = "72975") async throws -> String {
        guard let relay else { throw RelayError.badReply }
        let env = envelope(code: code, domain: domain, sender: sender)
        _ = try await post(relay.appendingPathComponent("v1/messages"), env, token: phoneToken)
        return env["id"] as! String
    }

    private func post(_ url: URL, _ body: [String: Any], token: String?) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw RelayError.http(status: (response as? HTTPURLResponse)?.statusCode ?? 0, code: nil)
        }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
}
