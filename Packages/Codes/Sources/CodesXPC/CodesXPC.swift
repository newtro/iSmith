import Foundation

/// The names that tie iSmith, its agent and the agent's Mach service together. Debug ("iSmith
/// Dev", `com.scottsmith.ismith.debug`) and Release (`com.scottsmith.ismith`) each get their own
/// agent, service, launchd plist and code-signing requirements, so a development build never talks
/// to, registers or replaces the installed app's agent.
public struct CodesIdentity: Equatable, Sendable {
    public static let teamID = "232A77467G"

    /// `com.scottsmith.ismith` or `com.scottsmith.ismith.debug`.
    public let appBundleID: String

    public init(appBundleID: String) {
        self.appBundleID = appBundleID
    }

    /// From the agent's own bundle id (`<app bundle id>.agent`).
    public init?(agentBundleID: String) {
        guard agentBundleID.hasSuffix(".agent") else { return nil }
        appBundleID = String(agentBundleID.dropLast(".agent".count))
    }

    /// `com.scottsmith.ismith.agent` / `com.scottsmith.ismith.debug.agent`; also the launchd label.
    public var agentBundleID: String { appBundleID + ".agent" }
    /// The XPC Mach service the agent publishes: `232A77467G.com.scottsmith.ismith.agent`.
    public var machServiceName: String { "\(Self.teamID).\(agentBundleID)" }
    /// The plist in `iSmith.app/Contents/Library/LaunchAgents/` that `SMAppService.agent` loads.
    public var launchAgentPlistName: String { agentBundleID + ".plist" }

    /// What the agent requires of a caller: the iSmith app of the same configuration, signed by
    /// the team.
    public var appRequirement: String { Self.requirement(identifier: appBundleID) }
    /// What the app requires of the agent it connects to.
    public var agentRequirement: String { Self.requirement(identifier: agentBundleID) }

    static func requirement(identifier: String) -> String {
        "anchor apple generic and certificate leaf[subject.OU] = \"\(teamID)\" and identifier \"\(identifier)\""
    }
}

/// The agent's XPC interface. Only plain types cross it (strings, `Data` holding JSON of the
/// `Codable` values below, booleans), so both sides decode with no class allow-lists. Every call
/// replies, so the app can tell a dead agent from a slow one.
@objc public protocol CodesAgentProtocol {
    /// `AgentStatus` as JSON.
    func status(reply: @escaping (Data) -> Void)
    /// Starts pairing with the relay. Replies with the QR URI and the pairing id, or an error.
    func startPairing(reply: @escaping (_ uri: String?, _ pairingID: String?, _ error: String?) -> Void)
    /// `PairingInfo` as JSON.
    func pairingState(reply: @escaping (Data) -> Void)
    /// "They match": activates the pairing. Replies with an error, or nil.
    func confirmPairing(reply: @escaping (_ error: String?) -> Void)
    /// Cancels a pairing in progress (the relay forgets it).
    func cancelPairing(reply: @escaping () -> Void)
    /// Revokes the pairing at the relay and forgets the keys, token and phone. Replies with a
    /// warning (the relay couldn't be told), or nil.
    func unpair(reply: @escaping (_ warning: String?) -> Void)
    /// `[CodeOffer]` as JSON. With a host, only the codes that may be offered on that page
    /// (PROTOCOL.md §5); with nil, every recent code (for Settings).
    func recentCodes(forHost host: String?, reply: @escaping (Data) -> Void)
    /// The code was filled; it isn't offered again.
    func markUsed(_ id: String, reply: @escaping () -> Void)
    /// `CodesSettings` as JSON.
    func settings(reply: @escaping (Data) -> Void)
    /// Saves `CodesSettings` (JSON). Replies with an error, or nil.
    func setSettings(_ json: Data, reply: @escaping (_ error: String?) -> Void)
    /// Exits after replying. launchd's KeepAlive starts the agent again, from the bundle now on
    /// disk: the app calls this after a Sparkle update when the agent's version isn't its own.
    func quit(reply: @escaping () -> Void)
}

/// What the agent reports about itself.
public struct AgentStatus: Codable, Equatable, Sendable {
    public var paired: Bool
    public var phoneName: String?
    /// The relay stream is open.
    public var connected: Bool
    public var lastMessageAt: Date?
    /// "1.3.7 (42)": the agent bundle's CFBundleShortVersionString and CFBundleVersion.
    public var agentVersion: String
    /// Why the agent can't work (a Keychain error, a revoked pairing), for Settings to show.
    public var problem: String?
    /// The agent's process id, so a caller can tell a restarted agent from the old one.
    public var processID: Int32

    public init(paired: Bool, phoneName: String?, connected: Bool, lastMessageAt: Date?,
                agentVersion: String, problem: String? = nil,
                processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        self.paired = paired
        self.phoneName = phoneName
        self.connected = connected
        self.lastMessageAt = lastMessageAt
        self.agentVersion = agentVersion
        self.problem = problem
        self.processID = processID
    }
}

/// Where a pairing stands.
public struct PairingInfo: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        /// Nothing in progress (look at `AgentStatus.paired`).
        case idle
        /// The QR code is up; waiting for the phone.
        case waiting
        /// The phone answered and its proof checked out: compare the fingerprints.
        case verify
        /// Paired.
        case active
        /// The phone's proof didn't check out, the relay refused, or the pairing expired.
        case failed
    }

    public var state: State
    /// "123 456" while verifying.
    public var fingerprint: String?
    public var phoneName: String?
    /// For `.failed`: what went wrong, in a sentence.
    public var message: String?

    public init(state: State, fingerprint: String? = nil, phoneName: String? = nil, message: String? = nil) {
        self.state = state
        self.fingerprint = fingerprint
        self.phoneName = phoneName
        self.message = message
    }
}

/// A code the agent received, as the app may offer it.
public struct CodeOffer: Codable, Equatable, Sendable {
    /// The message id (a UUID).
    public var id: String
    public var code: String
    /// The SMS sender as the phone reported it ("+15551234567", "72975").
    public var sender: String
    /// The WebOTP domain the code is bound to, or nil.
    public var domain: String?
    /// When the Mac received it.
    public var receivedAt: Date

    public init(id: String, code: String, sender: String, domain: String?, receivedAt: Date) {
        self.id = id
        self.code = code
        self.sender = sender
        self.domain = domain
        self.receivedAt = receivedAt
    }
}

/// Settings ▸ Codes.
public struct CodesSettings: Codable, Equatable, Sendable {
    /// A notification for each code.
    public var notifications: Bool
    /// Copy each code to the clipboard as it arrives (off by default).
    public var copyToClipboard: Bool
    /// Offer recent codes in iSmith's code fields.
    public var offerInBrowser: Bool

    public static let defaults = CodesSettings(notifications: true, copyToClipboard: false, offerInBrowser: true)

    public init(notifications: Bool, copyToClipboard: Bool, offerInBrowser: Bool) {
        self.notifications = notifications
        self.copyToClipboard = copyToClipboard
        self.offerInBrowser = offerInBrowser
    }

    public init(from decoder: Decoder) throws {
        // A field added later reads as its default in an older file.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? d.notifications
        copyToClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyToClipboard) ?? d.copyToClipboard
        offerInBrowser = try c.decodeIfPresent(Bool.self, forKey: .offerInBrowser) ?? d.offerInBrowser
    }
}

/// The JSON coding both sides use (dates as Unix milliseconds).
public enum CodesJSON {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .millisecondsSince1970
        e.outputFormatting = [.sortedKeys]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .millisecondsSince1970
        return d
    }

    public static func encode<T: Encodable>(_ value: T) -> Data {
        (try? encoder().encode(value)) ?? Data("null".utf8)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        try? decoder().decode(type, from: data)
    }
}

/// Formats a 6-digit fingerprint as "123 456".
public func groupedFingerprint(_ digits: String) -> String {
    guard digits.count == 6 else { return digits }
    return "\(digits.prefix(3)) \(digits.suffix(3))"
}
