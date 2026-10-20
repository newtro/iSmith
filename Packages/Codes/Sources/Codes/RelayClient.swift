import Foundation
import os

/// The package's log. Nothing logs a code, an SMS body, a key or a token: only ids, states and
/// error kinds.
let codesLog = Logger(subsystem: "com.scottsmith.ismith.codes", category: "codes")

public enum RelayError: Error, Equatable, CustomStringConvertible {
    /// A non-2xx reply with the relay's `{"error": "<code>"}`.
    case http(status: Int, code: String?)
    /// The reply wasn't what the protocol says.
    case badReply
    /// The token was refused (401): the pairing is gone.
    case unauthorized

    public var description: String {
        switch self {
        case let .http(status, code): return "The relay answered \(status)\(code.map { " (\($0))" } ?? "")."
        case .badReply: return "The relay's reply wasn't understood."
        case .unauthorized: return "The relay no longer knows this Mac."
        }
    }
}

/// The relay's HTTP API (PROTOCOL.md §4).
public struct RelayAPI: Sendable {
    public let baseURL: URL
    public let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    /// `wss://…/v1/stream` (`ws://` for a plain-http relay in tests).
    public var streamURL: URL {
        var parts = URLComponents(url: url("/v1/stream"), resolvingAgainstBaseURL: false)!
        parts.scheme = parts.scheme == "http" ? "ws" : "wss"
        return parts.url!
    }

    func url(_ path: String) -> URL {
        URL(string: PairingSession.baseString(baseURL) + path)!
    }

    public func pairStart(macName: String) async throws -> PairStartReply {
        try await call("POST", "/v1/pair/start", token: nil, body: ["macName": macName], expect: [201, 200])
    }

    public func pairStatus(token: String) async throws -> PairStatusReply {
        try await call("GET", "/v1/pair", token: token, body: nil, expect: [200])
    }

    public func pairConfirm(token: String) async throws {
        let _: Ignored = try await call("POST", "/v1/pair/confirm", token: token, body: [String: String](), expect: [200])
    }

    public func pairDelete(token: String) async throws {
        let _: Ignored = try await call("DELETE", "/v1/pair", token: token, body: nil, expect: [204, 200])
    }

    public func ack(ids: [String], token: String) async throws {
        for start in stride(from: 0, to: ids.count, by: 100) {
            let chunk = Array(ids[start..<min(start + 100, ids.count)])
            let _: Ignored = try await call("POST", "/v1/ack", token: token, body: ["ids": chunk], expect: [200])
        }
    }

    struct Ignored: Decodable {}

    private func call<Body: Encodable, Reply: Decodable>(_ method: String, _ path: String, token: String?, body: Body?,
                                                         expect: Set<Int>) async throws -> Reply {
        var request = URLRequest(url: url(path))
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw RelayError.badReply }
        if http.statusCode == 401 { throw RelayError.unauthorized }
        guard expect.contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode([String: String].self, from: data))?["error"]
            throw RelayError.http(status: http.statusCode, code: code)
        }
        if Reply.self == Ignored.self { return Ignored() as! Reply }
        do { return try JSONDecoder().decode(Reply.self, from: data) } catch { throw RelayError.badReply }
    }

    private func call<Reply: Decodable>(_ method: String, _ path: String, token: String?, body: Never?,
                                        expect: Set<Int>) async throws -> Reply {
        try await call(method, path, token: token, body: Optional<[String: String]>.none, expect: expect)
    }
}

/// What the stream tells its owner.
public enum StreamEvent: Sendable {
    case connected
    case disconnected
    /// An envelope. The owner processes it and returns; the stream then acks its id.
    case message(Envelope)
    /// The relay revoked the pairing (or refused the token): the stream has stopped for good.
    case revoked
}

/// The Mac's WebSocket to the relay (`GET /v1/stream`): reconnects with exponential backoff and
/// jitter, treats 60 s without a frame or a pong as a dead connection, and acks each message only
/// after its handler returned.
public final class RelayStream: @unchecked Sendable {
    public struct Timing: Sendable {
        /// The first retry delay, doubled per failure up to `maxBackoff`; each delay is then
        /// multiplied by a random factor in 0.5…1.0.
        public var initialBackoff: TimeInterval = 1
        public var maxBackoff: TimeInterval = 60
        /// We ping this often: URLSession answers the relay's pings without telling us, so our
        /// own pings' pongs are what shows the connection is alive.
        public var pingInterval: TimeInterval = 25
        /// No frame and no pong for this long: reconnect.
        public var livenessTimeout: TimeInterval = 60
        /// A connection that stayed up this long resets the backoff.
        public var stableAfter: TimeInterval = 30
        /// The least wait after the relay closed us with 4409 (another stream replaced this one).
        public var replacedBackoff: TimeInterval = 30

        public init() {}
    }

    public typealias Handler = @Sendable (StreamEvent) async -> Void

    private let url: URL
    private let token: String
    private let session: URLSession
    private let timing: Timing
    private let handler: Handler
    private let fallbackAck: (@Sendable ([String]) async -> Void)?

    private let lock = NSLock()
    private var runner: Task<Void, Never>?
    private var task: URLSessionWebSocketTask?
    private var lastActivity = Date()
    private var _isConnected = false

    /// - fallbackAck: used when an ack can't go over the socket (it closed meanwhile).
    public init(url: URL, token: String, session: URLSession = URLSession(configuration: .ephemeral),
                timing: Timing = Timing(), fallbackAck: (@Sendable ([String]) async -> Void)? = nil,
                handler: @escaping Handler) {
        self.url = url
        self.token = token
        self.session = session
        self.timing = timing
        self.fallbackAck = fallbackAck
        self.handler = handler
    }

    public var isConnected: Bool { lock.withLock { _isConnected } }

    public func start() {
        lock.withLock {
            guard runner == nil else { return }
            runner = Task { [weak self] in await self?.run() }
        }
    }

    public func stop() {
        let (r, t) = lock.withLock { () -> (Task<Void, Never>?, URLSessionWebSocketTask?) in
            defer { runner = nil; task = nil }
            return (runner, task)
        }
        r?.cancel()
        t?.cancel(with: .goingAway, reason: nil)
    }

    private func run() async {
        var failures = 0
        while !Task.isCancelled {
            let opened = Date()
            let outcome = await connectOnce()
            if Task.isCancelled { break }
            if outcome == .revoked {
                await handler(.revoked)
                break
            }
            var delay: TimeInterval
            if outcome == .replaced {
                // Another stream for this pairing took over (close 4409). Reconnecting at once
                // would just knock that one off in turn, so wait well past the usual backoff.
                delay = max(timing.replacedBackoff, Self.backoff(failures: failures, timing: timing))
            } else {
                if Date().timeIntervalSince(opened) >= timing.stableAfter { failures = 0 }
                delay = Self.backoff(failures: failures, timing: timing)
            }
            failures += 1
            codesLog.info("stream closed; reconnecting in \(delay, format: .fixed(precision: 1), privacy: .public) s")
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }
        lock.withLock { runner = nil }
    }

    /// The delay before reconnect attempt `failures + 1`.
    public static func backoff(failures: Int, timing: Timing, random: Double = Double.random(in: 0.5...1.0)) -> TimeInterval {
        let base = min(timing.maxBackoff, timing.initialBackoff * pow(2, Double(min(failures, 20))))
        return base * random
    }

    private enum Outcome { case closed, revoked, replaced }

    private func connectOnce() async -> Outcome {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let ws = session.webSocketTask(with: request)
        ws.maximumMessageSize = 64 * 1024
        lock.withLock { task = ws; lastActivity = Date() }
        ws.resume()
        // A pong to this first ping means the upgrade went through: the stream is open even when
        // the relay has nothing queued and sends no frame.
        ws.sendPing { [weak self] error in
            guard error == nil, let self else { return }
            self.touch()
            Task { await self.markConnected(ws) }
        }

        // The watchdog pings and enforces the liveness timeout; it cancels the socket, which ends
        // the receive loop below.
        let watchdog = Task { [weak self, timing] in
            var sincePing: TimeInterval = 0
            let tick = min(1.0, timing.pingInterval / 4)
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                guard let self, !Task.isCancelled else { return }
                sincePing += tick
                if sincePing >= timing.pingInterval {
                    sincePing = 0
                    ws.sendPing { [weak self] error in
                        if error == nil { self?.touch() }
                    }
                }
                if Date().timeIntervalSince(self.lock.withLock({ self.lastActivity })) > timing.livenessTimeout {
                    codesLog.info("stream silent too long; reconnecting")
                    ws.cancel(with: .goingAway, reason: nil)
                    return
                }
            }
        }
        defer {
            watchdog.cancel()
            ws.cancel(with: .goingAway, reason: nil)
            let wasConnected = lock.withLock { () -> Bool in
                defer { _isConnected = false; if task === ws { task = nil } }
                return _isConnected
            }
            if wasConnected { Task { [handler] in await handler(.disconnected) } }
        }

        while !Task.isCancelled {
            let frame: URLSessionWebSocketTask.Message
            do {
                frame = try await ws.receive()
            } catch {
                if let http = ws.response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                    codesLog.error("stream refused the token (\(http.statusCode, privacy: .public))")
                    return .revoked
                }
                if ws.closeCode.rawValue == 4401 { return .revoked }
                if ws.closeCode.rawValue == 4409 { return .replaced }
                return .closed
            }
            touch()
            await markConnected(ws)
            let data: Data
            switch frame {
            case let .string(text): data = Data(text.utf8)
            case let .data(d): data = d
            @unknown default: continue
            }
            guard let parsed = try? JSONDecoder().decode(StreamFrame.self, from: data) else {
                codesLog.error("stream frame not understood; ignored")
                continue
            }
            switch parsed {
            case let .message(envelope, _):
                await handler(.message(envelope))
                await sendAck([envelope.id], on: ws)
            case .revoked:
                return .revoked
            case .other:
                continue
            }
        }
        return .closed
    }

    private func markConnected(_ ws: URLSessionWebSocketTask) async {
        let became = lock.withLock { () -> Bool in
            guard task === ws, !_isConnected else { return false }
            _isConnected = true
            return true
        }
        if became { await handler(.connected) }
    }

    /// Something arrived (a frame or a pong): the connection is alive.
    private func touch() {
        lock.withLock { lastActivity = Date() }
    }

    private func sendAck(_ ids: [String], on ws: URLSessionWebSocketTask) async {
        let frame = (try? JSONSerialization.data(withJSONObject: ["type": "ack", "ids": ids])) ?? Data()
        do {
            try await ws.send(.string(String(decoding: frame, as: UTF8.self)))
        } catch {
            await fallbackAck?(ids)
        }
    }
}
