import CryptoKit
import Foundation
import Network

/// A stand-in for the 2FASync relay (PROTOCOL.md §4) on 127.0.0.1, over real sockets: the HTTP
/// API and the WebSocket stream on one port, so the Mac's client is tested exactly as it runs
/// (URLSession, the Authorization header on the upgrade, pings, acks). Plain http/ws only; it is a
/// test fixture, not a relay. The tests drive it in process; the `FakeRelay` executable serves it
/// for a local end-to-end run of the real agent.
public final class FakeRelayServer: @unchecked Sendable {
    public struct Pairing {
        public var id: String
        public var state: String // waiting, pending, active
        public var registrationToken: String
        public var macToken: String
        public var phoneToken: String?
        public var macName: String
        public var phonePublicKey: String?
        public var phoneName: String?
        public var proof: String?
        public var expiresAt: Int64
        public var queue: [(envelope: [String: Any], receivedAt: Int64)] = []
    }

    let queue = DispatchQueue(label: "fake-relay")
    private var listener: NWListener?
    public private(set) var port: UInt16 = 0

    // State, only touched on `queue`.
    private var pairings: [String: Pairing] = [:]
    private var streams: [String: WebSocketPeer] = [:]
    private var _acked: [String] = []
    private var _streamConnections = 0
    private var _deletes = 0
    private var _confirms = 0

    /// When set, `pair/complete` stores this public key instead of the phone's (a key-swapping relay).
    public var swapPhoneKey: String? {
        get { queue.sync { _swapPhoneKey } }
        set { queue.sync { _swapPhoneKey = newValue } }
    }
    private var _swapPhoneKey: String?

    /// Whether the stream answers the client's pings (false simulates a dead connection).
    public var answersPings: Bool {
        get { queue.sync { _answersPings } }
        set { queue.sync { _answersPings = newValue } }
    }
    private var _answersPings = true

    /// When set, the stream upgrade is answered with this status (403, 500…) instead of 101.
    public var refuseUpgrades: Int? {
        get { queue.sync { _refuseUpgrades } }
        set { queue.sync { _refuseUpgrades = newValue } }
    }
    private var _refuseUpgrades: Int?
    public var refusedUpgrades: Int { queue.sync { _refusedUpgrades } }
    private var _refusedUpgrades = 0

    /// The relay pings the client this often (PROTOCOL.md: 25 s).
    public var pingInterval: TimeInterval = 25

    public init() {}

    public var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    public func start(port requested: UInt16 = 0) throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: requested) ?? .any)
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ready.signal()
            case let .failed(error): failure = error; ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let failure { throw failure }
        port = listener.port?.rawValue ?? 0
        schedulePings()
    }

    public func stopServer() {
        queue.sync {
            listener?.cancel()
            for peer in streams.values { peer.connection.cancel() }
            streams = [:]
        }
    }

    // MARK: - Test controls

    public var ackedIDs: [String] { queue.sync { _acked } }
    public var streamConnections: Int { queue.sync { _streamConnections } }
    public var deleteCount: Int { queue.sync { _deletes } }
    public var confirmCount: Int { queue.sync { _confirms } }
    public func pairing(_ id: String) -> Pairing? { queue.sync { pairings[id] } }
    public var allPairings: [Pairing] { queue.sync { Array(pairings.values) } }
    public var hasOpenStream: Bool { queue.sync { !streams.isEmpty } }

    /// Queues an envelope for the pairing (as `POST /v1/messages` would) and pushes it to an open stream.
    public func enqueue(_ envelope: [String: Any], pairingID: String) {
        queue.sync { deliver(envelope, to: pairingID) }
    }

    /// Revokes a pairing: the open stream gets `{"type":"revoked"}` and close 4401.
    public func revoke(_ pairingID: String) {
        queue.sync { revokeLocked(pairingID) }
    }

    /// Closes every open stream (abruptly), as a relay restart would.
    public func dropStreams() {
        queue.sync {
            for peer in streams.values { peer.connection.cancel() }
            streams = [:]
        }
    }

    // MARK: - Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let request = HTTPRequest(parse: buffer) {
                self.route(request, connection)
            } else if done || error != nil || buffer.count > 64 * 1024 {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func reply(_ connection: NWConnection, _ status: Int, _ json: Any? = nil) {
        let body = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let reason = [101: "Switching Protocols", 200: "OK", 201: "Created", 202: "Accepted", 204: "No Content",
                      400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 409: "Conflict"][status] ?? "Status"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\n"
        if status != 204 { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        if status != 204 { out.append(body) }
        connection.send(content: out, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func error(_ connection: NWConnection, _ status: Int, _ code: String) {
        reply(connection, status, ["error": code])
    }

    private func bearer(_ request: HTTPRequest) -> String? {
        guard let auth = request.headers["authorization"], auth.hasPrefix("Bearer ") else { return nil }
        return String(auth.dropFirst(7))
    }

    /// The pairing a token belongs to, and whether it's the Mac's.
    private func lookup(_ token: String?) -> (id: String, isMac: Bool)? {
        guard let token else { return nil }
        for (id, p) in pairings {
            if p.macToken == token { return (id, true) }
            if p.phoneToken == token { return (id, false) }
        }
        return nil
    }

    private func now() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

    private func route(_ request: HTTPRequest, _ connection: NWConnection) {
        let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] ?? [:]
        switch (request.method, request.path) {
        case ("GET", "/v1/health"):
            reply(connection, 200, ["ok": true])

        case ("POST", "/v1/pair/start"):
            let id = UUID().uuidString.lowercased()
            let p = Pairing(id: id, state: "waiting", registrationToken: Self.token(), macToken: Self.token(),
                            macName: json["macName"] as? String ?? "Mac", expiresAt: now() + 600_000)
            pairings[id] = p
            reply(connection, 201, ["pairingId": id, "registrationToken": p.registrationToken,
                                    "macToken": p.macToken, "expiresAt": p.expiresAt])

        case ("POST", "/v1/pair/complete"):
            guard let id = json["pairingId"] as? String, var p = pairings[id],
                  p.registrationToken == json["registrationToken"] as? String else { return error(connection, 401, "bad_token") }
            guard p.state == "waiting" else { return error(connection, 409, "already_completed") }
            p.state = "pending"
            p.phonePublicKey = _swapPhoneKey ?? json["phonePublicKey"] as? String
            p.phoneName = json["phoneName"] as? String
            p.proof = json["proof"] as? String
            p.phoneToken = Self.token()
            pairings[id] = p
            reply(connection, 200, ["phoneToken": p.phoneToken!])

        case ("GET", "/v1/pair"):
            guard let who = lookup(bearer(request)), let p = pairings[who.id] else { return error(connection, 401, "unauthorized") }
            if who.isMac {
                var out: [String: Any] = ["state": p.state]
                if p.state != "waiting" {
                    out["phonePublicKey"] = p.phonePublicKey
                    out["phoneName"] = p.phoneName
                    out["proof"] = p.proof
                }
                reply(connection, 200, out)
            } else {
                reply(connection, 200, ["state": p.state, "macName": p.macName])
            }

        case ("POST", "/v1/pair/confirm"):
            guard let who = lookup(bearer(request)), who.isMac, var p = pairings[who.id] else { return error(connection, 401, "unauthorized") }
            guard p.state == "pending" else { return error(connection, 409, "not_pending") }
            p.state = "active"
            pairings[who.id] = p
            _confirms += 1
            reply(connection, 200, ["state": "active"])

        case ("DELETE", "/v1/pair"):
            guard let who = lookup(bearer(request)) else { return error(connection, 401, "unauthorized") }
            _deletes += 1
            revokeLocked(who.id)
            reply(connection, 204)

        case ("POST", "/v1/messages"):
            guard let who = lookup(bearer(request)), !who.isMac, pairings[who.id]?.state == "active" else {
                return error(connection, 401, "unauthorized")
            }
            guard let id = json["id"] as? String else { return error(connection, 400, "bad_envelope") }
            if pairings[who.id]?.queue.contains(where: { $0.envelope["id"] as? String == id }) == true {
                return reply(connection, 200, ["id": id, "duplicate": true])
            }
            deliver(json, to: who.id)
            reply(connection, 202, ["id": id])

        case ("POST", "/v1/ack"):
            guard let who = lookup(bearer(request)), who.isMac else { return error(connection, 401, "unauthorized") }
            let n = ack(json["ids"] as? [String] ?? [], pairingID: who.id)
            reply(connection, 200, ["deleted": n])

        case ("GET", "/v1/stream"):
            guard request.headers["upgrade"]?.lowercased() == "websocket", let key = request.headers["sec-websocket-key"] else {
                return error(connection, 400, "not_websocket")
            }
            guard let who = lookup(bearer(request)), who.isMac, pairings[who.id]?.state == "active" else {
                return error(connection, 401, "unauthorized")
            }
            if let status = _refuseUpgrades {
                _refusedUpgrades += 1
                return error(connection, status, "refused")
            }
            upgrade(connection, key: key, pairingID: who.id)

        // Test hooks for the FakeRelay executable: a phone driven by curl.
        case ("POST", "/test/phone/pair"):
            guard let uri = json["uri"] as? String else { return error(connection, 400, "uri") }
            let name = json["phoneName"] as? String ?? "Test Phone"
            Task.detached {
                let phone = FakePhone(name: name)
                do {
                    // Through the relay the URI names: this server, or a real relay run locally.
                    try await phone.pair(uri: uri)
                    FakePhone.shared = phone
                } catch {
                    FileHandle.standardError.write(Data("fake phone pairing failed: \(error)\n".utf8))
                }
            }
            reply(connection, 202, ["ok": true])

        case ("POST", "/test/phone/send"):
            guard let phone = FakePhone.shared else { return error(connection, 409, "not_paired") }
            let code = json["code"] as? String ?? "123456"
            let domain = json["domain"] as? String
            let sender = json["sender"] as? String ?? "72975"
            Task.detached {
                do { _ = try await phone.send(code: code, domain: domain, sender: sender) } catch {
                    FileHandle.standardError.write(Data("fake phone send failed: \(error)\n".utf8))
                }
            }
            reply(connection, 202, ["ok": true])

        default:
            error(connection, 404, "not_found")
        }
    }

    private func deliver(_ envelope: [String: Any], to pairingID: String) {
        let at = now()
        pairings[pairingID]?.queue.append((envelope, at))
        streams[pairingID]?.sendText(Self.messageFrame(envelope, at))
    }

    @discardableResult
    private func ack(_ ids: [String], pairingID: String) -> Int {
        _acked.append(contentsOf: ids)
        let before = pairings[pairingID]?.queue.count ?? 0
        pairings[pairingID]?.queue.removeAll { ids.contains($0.envelope["id"] as? String ?? "") }
        return before - (pairings[pairingID]?.queue.count ?? 0)
    }

    private func revokeLocked(_ pairingID: String) {
        pairings[pairingID] = nil
        if let peer = streams.removeValue(forKey: pairingID) {
            peer.sendText(#"{"type":"revoked"}"#)
            peer.sendClose(code: 4401)
        }
    }

    private static func messageFrame(_ envelope: [String: Any], _ at: Int64) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["type": "message", "envelope": envelope, "receivedAt": at])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func token() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    // MARK: - WebSocket

    private func upgrade(_ connection: NWConnection, key: String, pairingID: String) {
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        let peer = WebSocketPeer(connection: connection)
        if let old = streams[pairingID] { old.sendClose(code: 4409) }
        streams[pairingID] = peer
        _streamConnections += 1
        peer.onText = { [weak self, weak peer] text in
            guard let self, let peer, self.streams[pairingID] === peer,
                  let json = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
                  json["type"] as? String == "ack" else { return }
            self.ack(json["ids"] as? [String] ?? [], pairingID: pairingID)
        }
        peer.answersPings = { [weak self] in self?._answersPings ?? true }
        peer.onClose = { [weak self, weak peer] in
            guard let self, let peer, self.streams[pairingID] === peer else { return }
            self.streams[pairingID] = nil
        }
        for item in pairings[pairingID]?.queue ?? [] {
            peer.sendText(Self.messageFrame(item.envelope, item.receivedAt))
        }
        peer.readFrames()
    }

    private func schedulePings() {
        queue.asyncAfter(deadline: .now() + pingInterval) { [weak self] in
            guard let self, self.listener != nil else { return }
            for peer in self.streams.values { peer.sendPing() }
            self.schedulePings()
        }
    }
}

/// One server-side WebSocket (RFC 6455): unmasked frames out, masked frames in.
final class WebSocketPeer {
    let connection: NWConnection
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    var answersPings: () -> Bool = { true }
    private var buffer = Data()

    init(connection: NWConnection) {
        self.connection = connection
    }

    func sendText(_ text: String) { send(opcode: 0x1, payload: Data(text.utf8)) }
    func sendPing() { send(opcode: 0x9, payload: Data()) }

    func sendClose(code: UInt16) {
        send(opcode: 0x8, payload: Data([UInt8(code >> 8), UInt8(code & 0xff)]))
        connection.send(content: nil, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [connection] _ in
            connection.cancel()
        })
    }

    private func send(opcode: UInt8, payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count <= 0xffff {
            frame.append(126)
            frame.append(contentsOf: [UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xff)) }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .contentProcessed { _ in })
    }

    func readFrames() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            while let (opcode, payload) = self.nextFrame() {
                switch opcode {
                case 0x1: self.onText?(String(decoding: payload, as: UTF8.self))
                case 0x9: if self.answersPings() { self.send(opcode: 0xA, payload: payload) }
                case 0x8:
                    self.onClose?()
                    self.connection.cancel()
                    return
                default: break
                }
            }
            if done || error != nil {
                self.onClose?()
                self.connection.cancel()
                return
            }
            self.readFrames()
        }
    }

    private func nextFrame() -> (UInt8, Data)? {
        let b = [UInt8](buffer)
        guard b.count >= 2 else { return nil }
        let opcode = b[0] & 0x0f
        let masked = b[1] & 0x80 != 0
        var length = Int(b[1] & 0x7f)
        var i = 2
        if length == 126 {
            guard b.count >= 4 else { return nil }
            length = Int(b[2]) << 8 | Int(b[3]); i = 4
        } else if length == 127 {
            guard b.count >= 10 else { return nil }
            length = 0
            for j in 2..<10 { length = length << 8 | Int(b[j]) }
            i = 10
        }
        var mask: [UInt8] = []
        if masked {
            guard b.count >= i + 4 else { return nil }
            mask = Array(b[i..<i + 4]); i += 4
        }
        guard b.count >= i + length else { return nil }
        var payload = Array(b[i..<i + length])
        if masked { for k in payload.indices { payload[k] ^= mask[k % 4] } }
        buffer = Data(b[(i + length)...])
        return (opcode, Data(payload))
    }
}

/// A parsed HTTP/1.1 request (headers lowercased), once all of it has arrived.
struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    init?(parse data: Data) {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: data[..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return nil }
        method = String(first[0])
        path = String(first[1].split(separator: "?").first ?? "")
        self.headers = headers
        body = data[bodyStart..<bodyStart + length]
    }
}
