import CodesXPC
import Foundation

/// iSmith's side of the iSmith Agent's XPC service (2FASync codes; see
/// Packages/Codes/INTEGRATION.md). The connection requires the agent of this build's
/// configuration, signed by the team; the agent requires this app in turn. iSmith never sees the
/// Mac's key or relay token: it asks the agent.
@MainActor
final class CodesClient {
    static let shared = CodesClient()

    /// The names for this build: Debug's agent is `com.scottsmith.ismith.debug.agent`.
    static var identity: CodesIdentity {
        #if DEBUG
        // As AppIdentity's Keychain names: a Debug build never reaches the installed app's agent.
        let id = AppIdentity.bundleID == AppIdentity.releaseBundleID ? AppIdentity.releaseBundleID + ".debug" : AppIdentity.bundleID
        #else
        let id = AppIdentity.bundleID
        #endif
        return CodesIdentity(appBundleID: id)
    }

    /// The version the agent must report, "1.3.7 (42)": the same bundle ships both.
    static var appVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "?") (\(info["CFBundleVersion"] as? String ?? "?"))"
    }

    enum Failure: Error, CustomStringConvertible {
        case unreachable(String)
        case agent(String)
        case badReply

        var description: String {
            switch self {
            case let .unreachable(why): return "iSmith Agent isn't answering (\(why))."
            case let .agent(why): return why
            case .badReply: return "iSmith Agent's reply wasn't understood."
            }
        }
    }

    private var connection: NSXPCConnection?
    /// Pairing calls wait for the relay (up to 15 s per request), so this is longer than that.
    static let timeout: TimeInterval = 30

    private func connect() -> NSXPCConnection {
        if let connection { return connection }
        let identity = Self.identity
        let c = NSXPCConnection(machServiceName: identity.machServiceName, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: CodesAgentProtocol.self)
        c.setCodeSigningRequirement(identity.agentRequirement)
        c.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.connection = nil }
        }
        c.interruptionHandler = { [weak self] in
            // The agent exited (an update, a crash); the next call reconnects and launchd starts it.
            Task { @MainActor in self?.connection = nil }
        }
        c.resume()
        connection = c
        return c
    }

    /// Drops the connection (after the agent is unregistered or told to quit).
    func reset() {
        connection?.invalidate()
        connection = nil
    }

    /// One call: `body` gets the proxy and a resume function that must be called exactly once,
    /// unless the connection fails first.
    private func call<T>(_ body: @escaping (CodesAgentProtocol, @escaping (Result<T, Error>) -> Void) -> Void) async throws -> T {
        let connection = connect()
        return try await withCheckedThrowingContinuation { continuation in
            let once = XPCReplyOnce()
            let finish: (Result<T, Error>) -> Void = { result in
                guard once.claim() else { return }
                continuation.resume(with: result)
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                finish(.failure(Failure.unreachable(error.localizedDescription)))
            }
            guard let agent = proxy as? CodesAgentProtocol else {
                return finish(.failure(Failure.unreachable("no proxy")))
            }
            // An agent that's alive answers in milliseconds; one that's stuck doesn't hold the UI.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout) {
                finish(.failure(Failure.unreachable("no answer in \(Int(Self.timeout)) seconds")))
            }
            body(agent, finish)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> Result<T, Error> {
        CodesJSON.decode(type, from: data).map { .success($0) } ?? .failure(Failure.badReply)
    }

    // MARK: - The interface

    func status() async throws -> AgentStatus {
        try await call { agent, done in agent.status { done(self.decode(AgentStatus.self, $0)) } }
    }

    func startPairing() async throws -> (uri: String, pairingID: String) {
        try await call { agent, done in
            agent.startPairing { uri, id, error in
                if let uri, let id { done(.success((uri, id))) } else { done(.failure(Failure.agent(error ?? "Pairing didn't start."))) }
            }
        }
    }

    func pairingState() async throws -> PairingInfo {
        try await call { agent, done in agent.pairingState { done(self.decode(PairingInfo.self, $0)) } }
    }

    func confirmPairing() async throws {
        try await call { agent, done in
            agent.confirmPairing { error in done(error.map { .failure(Failure.agent($0)) } ?? .success(())) }
        }
    }

    func cancelPairing() async throws {
        try await call { agent, done in agent.cancelPairing { done(.success(())) } }
    }

    /// Returns a warning when the relay couldn't be told.
    func unpair() async throws -> String? {
        try await call { agent, done in agent.unpair { done(.success($0)) } }
    }

    /// The codes that may be offered on a page with this top-level host (PROTOCOL.md §5), or
    /// every recent code for nil. For the code-field autofill (next phase) and Settings.
    func recentCodes(for host: String?) async throws -> [CodeOffer] {
        try await call { agent, done in agent.recentCodes(forHost: host) { done(self.decode([CodeOffer].self, $0)) } }
    }

    /// The code was filled; the agent stops offering it.
    func markUsed(_ id: String) async throws {
        try await call { agent, done in agent.markUsed(id) { done(.success(())) } }
    }

    func settings() async throws -> CodesSettings {
        try await call { agent, done in agent.settings { done(self.decode(CodesSettings.self, $0)) } }
    }

    func setSettings(_ settings: CodesSettings) async throws {
        try await call { agent, done in
            agent.setSettings(CodesJSON.encode(settings)) { error in done(error.map { .failure(Failure.agent($0)) } ?? .success(())) }
        }
    }

    func quit() async throws {
        try await call { agent, done in agent.quit { done(.success(())) } }
        reset()
    }
}

/// Lets exactly one of an XPC reply and its error handler finish a call.
private final class XPCReplyOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func claim() -> Bool {
        lock.withLock {
            if done { return false }
            done = true
            return true
        }
    }
}
