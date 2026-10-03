import Foundation

/// A saved login. The username and password are secrets: `description`, `debugDescription` and
/// reflection (`dump`, `print`, string interpolation) redact them, so a login logged by mistake
/// leaks nothing but its id and origin. The type isn't `Codable` for the same reason.
public struct Login: Identifiable, Hashable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable {
    public let id: UUID
    public var origin: Origin
    public var username: String
    public var password: String
    public var created: Date
    /// When the password last changed.
    public var updated: Date
    /// When the login was last filled or signed in with.
    public var lastUsed: Date?
    public var timesUsed: Int

    public init(id: UUID = UUID(), origin: Origin, username: String, password: String,
                created: Date = Date(), updated: Date? = nil, lastUsed: Date? = nil, timesUsed: Int = 0) {
        self.id = id
        self.origin = origin
        self.username = username
        self.password = password
        self.created = created
        self.updated = updated ?? created
        self.lastUsed = lastUsed
        self.timesUsed = timesUsed
    }

    /// The login without its password, for lists and popovers.
    public var summary: LoginSummary {
        LoginSummary(id: id, origin: origin, username: username, lastUsed: lastUsed, matchKind: nil)
    }

    public var description: String { "Login(\(id.uuidString), \(origin), username: <redacted>, password: <redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "origin": origin, "username": "<redacted>", "password": "<redacted>"])
    }
}

/// What the autofill popover shows for a login: everything but the password. Filling goes back
/// to the store by `id`, so the password never passes through the app's UI code.
public struct LoginSummary: Identifiable, Hashable, Sendable, CustomStringConvertible, CustomReflectable {
    public let id: UUID
    public let origin: Origin
    public let username: String
    public let lastUsed: Date?
    /// How the login's origin fits the frame it's offered to; nil outside autofill.
    public let matchKind: MatchKind?

    public var description: String { "LoginSummary(\(id.uuidString), \(origin), username: <redacted>)" }
    public var customMirror: Mirror {
        Mirror(self, children: ["id": id, "origin": origin, "username": "<redacted>", "matchKind": matchKind as Any])
    }
}

/// A login offered for a frame, with how its origin matched.
public struct LoginMatch: Hashable, Sendable {
    public let login: Login
    public let kind: MatchKind

    public var summary: LoginSummary {
        LoginSummary(id: login.id, origin: login.origin, username: login.username,
                     lastUsed: login.lastUsed, matchKind: kind)
    }
}

/// What submitting a form should lead to, worked out by `PasswordStore.proposal(for:username:password:)`.
public enum SaveAction: Hashable, Sendable {
    /// No login for this origin and username yet: offer "Save password".
    case save
    /// A login with this username exists for the origin with another password: offer "Update".
    case update(existing: UUID)
    /// The login is already saved with this password. Nothing to ask; it's marked used.
    case unchanged(existing: UUID)
    /// The origin is on the "never save" list. Nothing to ask.
    case neverSave
}
