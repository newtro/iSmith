import CodesXPC
import Foundation

/// What the agent does with an accepted code (the notification, the clipboard). The relay ack
/// waits for this to return.
@MainActor
public protocol CodeSink: AnyObject {
    func deliver(_ message: CodeMessage, settings: CodesSettings) async
    /// The pairing is gone (unpaired or revoked): drop anything still showing its codes.
    func pairingForgotten()
}

/// What `pairing.json` (owner-only) holds: that a pairing exists, and its name for Settings. It
/// is never trusted for anything that matters; those fields are in the Keychain (`KeychainPairing`)
/// and the file's pairing id must match them.
struct PairingRecord: Codable, Equatable {
    var pairingId: String
    var phoneName: String
    var pairedAt: Date
}

/// The security-relevant part of a pairing, in one Keychain item the agent created: the Mac's
/// secret key and token, the phone's public key, the pairing id and the relay URL. A process that
/// can edit files but not the agent's Keychain items can't swap the phone's key or send the
/// token to another host.
struct KeychainPairing: Codable, Equatable {
    var pairingId: String
    var relayURL: URL
    var phonePublicKey: String
    var macSecretKey: String
    var macToken: String
}

/// The agent's engine: pairing, the relay stream, the receiver rules, recent codes and settings.
/// It has no UI; the agent's XPC service and notifications sit on top of it.
@MainActor
public final class CodesEngine {
    public struct Config {
        /// `pairing.json`, `seen.json` and `settings.json` go here.
        public var dataDir: URL
        /// The relay a new pairing uses (an existing pairing keeps its own).
        public var relayURL: URL
        public var macName: String
        public var agentVersion: String
        public var secrets: SecretStore
        public var session: URLSession
        public var streamTiming: RelayStream.Timing
        /// How often `GET /v1/pair` is read while waiting for the phone.
        public var pairPollInterval: TimeInterval
        /// Lets a relay on http://127.0.0.1 or http://localhost through (tests, a Debug agent).
        /// Otherwise the relay must be https.
        public var allowLocalHTTPRelay: Bool
        public var now: () -> Date

        public init(dataDir: URL, relayURL: URL, macName: String, agentVersion: String, secrets: SecretStore,
                    session: URLSession = URLSession(configuration: .ephemeral),
                    streamTiming: RelayStream.Timing = .init(), pairPollInterval: TimeInterval = 1,
                    allowLocalHTTPRelay: Bool = false, now: @escaping () -> Date = Date.init) {
            self.allowLocalHTTPRelay = allowLocalHTTPRelay
            self.dataDir = dataDir
            self.relayURL = relayURL
            self.macName = macName
            self.agentVersion = agentVersion
            self.secrets = secrets
            self.session = session
            self.streamTiming = streamTiming
            self.pairPollInterval = pairPollInterval
            self.now = now
        }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case alreadyPaired
        case nothingToConfirm
        case cancelled
        case insecureRelay
        case keychain(String)

        public var description: String {
            switch self {
            case .alreadyPaired: return "This Mac is already paired. Unpair first."
            case .nothingToConfirm: return "There's no pairing waiting to be confirmed."
            case .cancelled: return "The pairing was cancelled."
            case .insecureRelay: return "The relay must be an https address."
            case let .keychain(why): return "The Keychain refused the Mac's key (\(why))."
            }
        }
    }

    /// The Keychain item holding `KeychainPairing`.
    static let pairingSecretName = "pairing"
    /// Items written by builds before the pairing moved into one item; removed on unpair.
    static let legacySecretNames = ["mac-key", "mac-token"]

    public let config: Config
    public weak var sink: CodeSink?
    public let recent = RecentCodes()
    public private(set) var settings: CodesSettings
    public private(set) var lastMessageAt: Date?
    public private(set) var connected = false
    public private(set) var problem: String?

    private var record: PairingRecord?
    /// The relay of the active pairing (from the Keychain item, never from the file).
    private var relayURL: URL?
    private var macKeyPair: BoxKeyPair?
    private var macToken: String?
    private var receiver: Receiver?
    private var stream: RelayStream?

    private var pairing: PairingSession?
    private var verifiedPhone: (publicKey: Data, name: String)?
    private var pairingInfo = PairingInfo(state: .idle)
    private var pollTask: Task<Void, Never>?
    /// Bumped by every start, cancel and confirm: an await that comes back to a different
    /// generation was overtaken and must not change anything.
    private var pairingGeneration = 0
    private var confirming = false
    /// Bumped whenever a stream is started or stopped: events from an older stream (a late 401
    /// for a token since replaced) are ignored.
    private var streamGeneration = 0
    /// Set when the Keychain couldn't be read just now (locked, a refused prompt): retried.
    private var keychainRetry: Task<Void, Never>?

    var pairingURL: URL { config.dataDir.appendingPathComponent("pairing.json") }
    var seenURL: URL { config.dataDir.appendingPathComponent("seen.json") }
    var settingsURL: URL { config.dataDir.appendingPathComponent("settings.json") }

    public init(config: Config) {
        self.config = config
        settings = (try? Data(contentsOf: config.dataDir.appendingPathComponent("settings.json")))
            .flatMap { CodesJSON.decode(CodesSettings.self, from: $0) } ?? .defaults
        loadPairing()
    }

    public var isPaired: Bool { record != nil && receiver != nil }

    /// Opens the stream when paired.
    public func start() {
        if record != nil, receiver == nil { loadPairing() }
        guard isPaired else { return }
        startStream()
    }

    public func stop() {
        stopStream()
        pollTask?.cancel()
        pollTask = nil
        keychainRetry?.cancel()
        keychainRetry = nil
    }

    private func stopStream() {
        streamGeneration += 1
        stream?.stop()
        stream = nil
        connected = false
    }

    // MARK: - Status and settings

    public func status() -> AgentStatus {
        AgentStatus(paired: isPaired, phoneName: record?.phoneName, connected: connected,
                    lastMessageAt: lastMessageAt, agentVersion: config.agentVersion, problem: problem)
    }

    public func setSettings(_ new: CodesSettings) throws {
        try OwnerOnlyFile.write(CodesJSON.encode(new), to: settingsURL)
        settings = new
    }

    /// The codes that may be offered on a page with this top-level host (PROTOCOL.md §5): none
    /// when "offer in iSmith" is off or the host isn't a plain host name; never used ones.
    public func recentCodes(for host: String) -> [CodeOffer] {
        guard settings.offerInBrowser else { return [] }
        return recent.offers(for: host, now: config.now())
    }

    /// Every kept code with the code itself masked, for Settings' list.
    public func recentCodeSummaries() -> [CodeOffer] {
        recent.all(now: config.now()).map { offer in
            var masked = offer
            masked.code = String(repeating: "•", count: offer.code.count)
            return masked
        }
    }

    /// Whether a relay URL may carry the Mac's token: https, or a loopback http one when allowed.
    func relayAllowed(_ url: URL) -> Bool {
        guard url.host?.isEmpty == false, url.user == nil, url.query == nil else { return false }
        if url.scheme == "https" { return true }
        return config.allowLocalHTTPRelay && url.scheme == "http" && ["127.0.0.1", "localhost"].contains(url.host ?? "")
    }

    public func markUsed(_ id: String) { recent.markUsed(id) }

    // MARK: - Pairing

    /// `POST /v1/pair/start`, then polls `GET /v1/pair` until the phone answers. Returns the QR URI.
    public func startPairing() async throws -> (uri: String, pairingID: String) {
        // Also while a pairing file exists whose keys can't be read: unpair first.
        guard record == nil else { throw Failure.alreadyPaired }
        guard relayAllowed(config.relayURL) else { throw Failure.insecureRelay }
        await cancelPairing()
        pairingGeneration += 1
        let generation = pairingGeneration
        let api = RelayAPI(baseURL: config.relayURL, session: config.session)
        let reply = try await api.pairStart(macName: config.macName)
        guard UUID(uuidString: reply.pairingId) != nil, Base64URL.decode(reply.macToken)?.count == 32,
              Base64URL.decode(reply.registrationToken)?.count == 32
        else { throw RelayError.badReply }
        guard generation == pairingGeneration, record == nil else {
            // Cancelled (or another start began) while the relay answered: it forgets this one.
            try? await api.pairDelete(token: reply.macToken)
            throw Failure.cancelled
        }
        let session = PairingSession(relayURL: config.relayURL, reply: reply, macName: config.macName)
        pairing = session
        verifiedPhone = nil
        pairingInfo = PairingInfo(state: .waiting)
        codesLog.info("pairing \(session.pairingID, privacy: .public) started")
        pollTask = Task { [weak self] in await self?.poll(session) }
        return (session.qrURI, session.pairingID)
    }

    public func pairingState() -> PairingInfo {
        if isPaired, pairingInfo.state == .idle {
            return PairingInfo(state: .active, phoneName: record?.phoneName)
        }
        return pairingInfo
    }

    private func poll(_ session: PairingSession) async {
        let api = RelayAPI(baseURL: session.relayURL, session: config.session)
        while !Task.isCancelled, pairing?.pairingID == session.pairingID {
            if config.now() >= session.expiresAt {
                fail(session, "The pairing expired. Start again.")
                return
            }
            do {
                let status = try await api.pairStatus(token: session.macToken)
                guard !Task.isCancelled, pairing?.pairingID == session.pairingID else { return }
                switch status.state {
                case "waiting":
                    break
                case "pending":
                    switch session.check(status) {
                    case let .verified(pub, name, fingerprint):
                        verifiedPhone = (pub, name)
                        pairingInfo = PairingInfo(state: .verify, fingerprint: groupedFingerprint(fingerprint), phoneName: name)
                        codesLog.info("pairing \(session.pairingID, privacy: .public): proof checked out")
                    case .rejected:
                        codesLog.error("pairing \(session.pairingID, privacy: .public): proof did not match")
                        try? await api.pairDelete(token: session.macToken)
                        fail(session, "Pairing failed: the phone's key didn't check out.")
                    }
                    return
                default:
                    fail(session, "The relay ended the pairing. Start again.")
                    return
                }
            } catch RelayError.unauthorized {
                fail(session, "The pairing expired. Start again.")
                return
            } catch RelayError.http(404, _) {
                fail(session, "The pairing expired. Start again.")
                return
            } catch {
                // The network or the relay is down for a moment: keep asking until it expires.
            }
            try? await Task.sleep(nanoseconds: UInt64(config.pairPollInterval * 1_000_000_000))
        }
    }

    private func fail(_ session: PairingSession, _ message: String) {
        guard pairing?.pairingID == session.pairingID else { return }
        pairing = nil
        verifiedPhone = nil
        pairingInfo = PairingInfo(state: .failed, message: message)
    }

    /// "They match": `POST /v1/pair/confirm`, then keeps the keys, token and phone and opens the
    /// stream.
    public func confirmPairing() async throws {
        guard !confirming, let session = pairing, let phone = verifiedPhone, pairingInfo.state == .verify else {
            throw Failure.nothingToConfirm
        }
        confirming = true
        defer { confirming = false }
        let generation = pairingGeneration
        if config.now() >= session.expiresAt {
            fail(session, "The pairing expired. Start again.")
            throw Failure.nothingToConfirm
        }
        let api = RelayAPI(baseURL: session.relayURL, session: config.session)
        do {
            try await api.pairConfirm(token: session.macToken)
        } catch {
            fail(session, "The relay didn't accept the pairing (\(error)). Start again.")
            throw error
        }
        guard generation == pairingGeneration, pairing?.pairingID == session.pairingID else {
            // Cancelled while the relay confirmed; cancel already deleted it there.
            throw Failure.cancelled
        }
        let secret = KeychainPairing(pairingId: session.pairingID, relayURL: session.relayURL,
                                     phonePublicKey: Base64URL.encode(phone.publicKey),
                                     macSecretKey: Base64URL.encode(session.keyPair.secretKey), macToken: session.macToken)
        do {
            try config.secrets.save(CodesJSON.encode(secret), as: Self.pairingSecretName)
        } catch {
            try? await api.pairDelete(token: session.macToken)
            try? config.secrets.delete(Self.pairingSecretName)
            fail(session, "The Mac's key couldn't be saved in the Keychain (\(error)).")
            throw Failure.keychain("\(error)")
        }
        let record = PairingRecord(pairingId: session.pairingID, phoneName: phone.name, pairedAt: config.now())
        try? FileManager.default.removeItem(at: seenURL)
        SeenStore(fileURL: seenURL, pairingID: session.pairingID).create()
        try OwnerOnlyFile.write(CodesJSON.encode(record), to: pairingURL)
        pairing = nil
        verifiedPhone = nil
        problem = nil
        loadPairing()
        pairingInfo = PairingInfo(state: .idle)
        codesLog.info("pairing \(session.pairingID, privacy: .public) active")
        startStream()
    }

    /// Stops a pairing in progress; the relay forgets it.
    public func cancelPairing() async {
        pairingGeneration += 1
        pollTask?.cancel()
        pollTask = nil
        guard let session = pairing else {
            if pairingInfo.state != .idle { pairingInfo = PairingInfo(state: .idle) }
            return
        }
        pairing = nil
        verifiedPhone = nil
        pairingInfo = PairingInfo(state: .idle)
        try? await RelayAPI(baseURL: session.relayURL, session: config.session).pairDelete(token: session.macToken)
    }

    /// Revokes the pairing at the relay (best effort) and forgets it here either way.
    @discardableResult
    public func unpair() async -> String? {
        var warning: String?
        if let relayURL, let token = macToken {
            do {
                try await RelayAPI(baseURL: relayURL, session: config.session).pairDelete(token: token)
            } catch RelayError.unauthorized {
                // Already gone at the relay.
            } catch {
                warning = "The relay couldn't be told (\(error)); it forgets the pairing's messages within 10 minutes."
            }
        }
        forgetPairing()
        problem = nil
        return warning
    }

    private func forgetPairing() {
        stopStream()
        keychainRetry?.cancel()
        keychainRetry = nil
        for name in [Self.pairingSecretName] + Self.legacySecretNames { try? config.secrets.delete(name) }
        try? FileManager.default.removeItem(at: pairingURL)
        try? FileManager.default.removeItem(at: seenURL)
        record = nil
        relayURL = nil
        macKeyPair = nil
        macToken = nil
        receiver = nil
        recent.removeAll()
        pairingInfo = PairingInfo(state: .idle)
        sink?.pairingForgotten()
    }

    private func loadPairing() {
        guard let data = try? Data(contentsOf: pairingURL) else { return }
        guard let record = CodesJSON.decode(PairingRecord.self, from: data) else {
            problem = "The pairing file couldn't be read. Pair again."
            return
        }
        // From here on a pairing exists: a new one is refused until it's unpaired.
        self.record = record
        let stored: Data?
        do {
            stored = try config.secrets.load(Self.pairingSecretName)
        } catch {
            // Locked or refused just now: try again every 30 seconds.
            problem = "The Keychain couldn't be read (\(error)). Trying again."
            scheduleKeychainRetry()
            return
        }
        guard let stored, let secret = CodesJSON.decode(KeychainPairing.self, from: stored),
              let macSecret = Base64URL.decode(secret.macSecretKey), let pair = BoxKeyPair(secretKey: macSecret),
              let phonePub = Base64URL.decode(secret.phonePublicKey), phonePub.count == BoxCrypto.keyBytes,
              !secret.macToken.isEmpty
        else {
            problem = "The Mac's key for \(record.phoneName) is missing from the Keychain. Unpair, then pair again."
            return
        }
        guard secret.pairingId == record.pairingId else {
            codesLog.error("pairing file doesn't match the Keychain; not using either")
            problem = "The pairing file doesn't match the Keychain. Unpair, then pair again."
            return
        }
        guard relayAllowed(secret.relayURL) else {
            problem = "The pairing's relay isn't an https address. Unpair, then pair again."
            return
        }
        problem = nil
        relayURL = secret.relayURL
        macKeyPair = pair
        macToken = secret.macToken
        receiver = Receiver(phonePublicKey: phonePub, macSecretKey: pair.secretKey,
                            seen: SeenStore(fileURL: seenURL, pairingID: record.pairingId, expectFile: true, now: config.now()))
    }

    private func scheduleKeychainRetry() {
        guard keychainRetry == nil else { return }
        keychainRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            guard let self, !Task.isCancelled else { return }
            self.keychainRetry = nil
            guard self.record != nil, self.receiver == nil else { return }
            self.loadPairing()
            if self.isPaired { self.startStream() }
        }
    }

    // MARK: - The stream

    private func startStream() {
        guard let relayURL, let token = macToken, stream == nil else { return }
        streamGeneration += 1
        let generation = streamGeneration
        let api = RelayAPI(baseURL: relayURL, session: config.session)
        let stream = RelayStream(url: api.streamURL, token: token, session: config.session, timing: config.streamTiming,
                                 fallbackAck: { [weak self] ids in
                                     do {
                                         try await api.ack(ids: ids, token: token)
                                     } catch RelayError.unauthorized {
                                         // A 401 on any call with the Mac token means the pairing is gone.
                                         await self?.handle(.revoked, generation: generation)
                                     } catch {}
                                 },
                                 handler: { [weak self] event in await self?.handle(event, generation: generation) })
        self.stream = stream
        stream.start()
    }

    /// An event from the stream of `generation`; anything from an older stream is ignored.
    func handle(_ event: StreamEvent, generation: Int) async {
        guard generation == streamGeneration else { return }
        switch event {
        case .connected:
            connected = true
            codesLog.info("stream connected")
        case .disconnected:
            connected = false
        case let .message(envelope):
            if case let .accepted(message) = receive(envelope) {
                await sink?.deliver(message, settings: settings)
            }
        case .revoked:
            guard record != nil else { return }
            codesLog.error("pairing revoked by the relay")
            let name = record?.phoneName ?? "the phone"
            forgetPairing()
            problem = "The pairing with \(name) was revoked. Pair again to receive codes."
        }
    }

    /// Applies the receiver rules to one envelope (the stream acks it either way).
    @discardableResult
    func receive(_ envelope: Envelope) -> Receiver.Verdict {
        guard let receiver else { return .dropped(.boxDidNotOpen) }
        let now = config.now()
        let verdict = receiver.receive(envelope, now: now)
        switch verdict {
        case let .accepted(message):
            recent.add(message, receivedAt: now)
            lastMessageAt = now
            codesLog.info("message \(message.id, privacy: .public) accepted (ctr \(message.ctr, privacy: .public))")
        case let .dropped(why):
            codesLog.error("message \(envelope.id, privacy: .private) dropped: \(why.rawValue, privacy: .public)")
        }
        return verdict
    }
}
