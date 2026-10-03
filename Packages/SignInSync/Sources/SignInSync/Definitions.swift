import Foundation

/// A sign-in service whose cookies belong to an account rather than a space: an identity
/// provider (Microsoft, Google) or any site you want one sign-in for across spaces.
public struct ProviderDef: Codable, Hashable, Identifiable {
    public var id: String
    public var name: String
    /// Cookie domains owned by the provider: a cookie belongs to it when its domain equals one of
    /// these or is a subdomain of one.
    public var domains: [String]
    /// When set, only these cookie names are shared. Google sets many fast-changing tracking
    /// cookies on google.com; only its sign-in set needs to follow the account.
    public var names: [String]?
    /// Cookies that mean "signed in". When one appears in a space that has no account for this
    /// provider, the app offers to save the sign-in as an account. Empty means never offer.
    public var sessionNames: [String]?
    public var builtIn = false

    public init(id: String, name: String, domains: [String], names: [String]? = nil, sessionNames: [String]? = nil,
                builtIn: Bool = false) {
        (self.id, self.name, self.domains, self.names, self.sessionNames, self.builtIn) =
            (id, name, domains, names, sessionNames, builtIn)
    }

    public func owns(cookieDomain: String) -> Bool {
        var host = cookieDomain.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    public func tracks(_ cookie: HTTPCookie) -> Bool {
        owns(cookieDomain: cookie.domain) && (names.map { $0.contains(cookie.name) } ?? true)
    }

    public func tracks(record: CookieRecord) -> Bool {
        owns(cookieDomain: record.domain) && (names.map { $0.contains(record.name) } ?? true)
    }

    /// The cookies that carry a signed-in session; empty if the provider doesn't name them.
    public func session(_ records: [CookieRecord]) -> [String: String] {
        guard let sessionNames else { return [:] }
        var out: [String: String] = [:]
        for r in records where sessionNames.contains(r.name) && tracks(record: r) { out[r.key] = r.value }
        return out
    }

    public static let builtIns: [ProviderDef] = [
        // Only the session cookies are shared. Per-sign-in cookies (esctx, fpc, x-ms-gateway-slice)
        // stay in each space, so a sign-in in one space can't break one in progress in another.
        ProviderDef(id: "microsoft", name: "Microsoft",
                    domains: ["login.microsoftonline.com", "login.microsoft.com", "login.windows.net"],
                    names: ["ESTSAUTH", "ESTSAUTHPERSISTENT", "ESTSAUTHLIGHT", "ESTSSSOTILES", "buid", "SignInStateCookie"],
                    sessionNames: ["ESTSAUTH", "ESTSAUTHPERSISTENT"], builtIn: true),
        ProviderDef(id: "microsoft-personal", name: "Microsoft personal", domains: ["live.com"],
                    sessionNames: ["MSPAuth", "WLSSC"], builtIn: true),
        ProviderDef(id: "google", name: "Google", domains: ["google.com"], names: [
            "SID", "HSID", "SSID", "APISID", "SAPISID",
            "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
            "__Secure-1PSIDTS", "__Secure-3PSIDTS",
            "LSID", "__Host-1PLSID", "__Host-3PLSID", "__Host-GAPS", "ACCOUNT_CHOOSER",
        ], sessionNames: ["SID", "__Secure-1PSID"], builtIn: true),
        ProviderDef(id: "github", name: "GitHub", domains: ["github.com"],
                    names: ["user_session", "__Host-user_session_same_site", "logged_in", "dotcom_user"],
                    sessionNames: ["user_session"], builtIn: true),
    ]
}

/// One sign-in at one provider. Its provider cookies live in the vault and are shared by every
/// space bound to it.
public struct AccountDef: Codable, Hashable, Identifiable {
    public var id: String
    public var providerID: String
    public var name: String

    public init(id: String, providerID: String, name: String) {
        (self.id, self.providerID, self.name) = (id, providerID, name)
    }
}

/// A workspace with its own WebKit data store. By default it uses every provider's shared sign-in;
/// `bindings` holds only the exceptions.
public struct SpaceDef: Codable, Hashable, Identifiable {
    /// Binding value meaning "this provider's sign-in stays in this space only".
    public static let local = "local"

    public var id: String
    public var name: String
    public var color: Int
    public var storeID: UUID
    /// Provider id → a separate account id, or `SpaceDef.local`. Providers not listed use the
    /// provider's shared account.
    public var bindings: [String: String]
    public var home: String
    /// Providers whose sign-ins stay in this space only; the app won't offer to save them.
    public var localProviders: [String] = []

    public init(id: String, name: String, color: Int, storeID: UUID, bindings: [String: String], home: String,
                localProviders: [String] = []) {
        (self.id, self.name, self.color, self.storeID, self.bindings, self.home, self.localProviders) =
            (id, name, color, storeID, bindings, home, localProviders)
    }

    /// Fields added later decode with defaults, so an older config.json still loads.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        color = try c.decodeIfPresent(Int.self, forKey: .color) ?? 0
        storeID = try c.decode(UUID.self, forKey: .storeID)
        bindings = try c.decodeIfPresent([String: String].self, forKey: .bindings) ?? [:]
        home = try c.decodeIfPresent(String.self, forKey: .home) ?? ""
        localProviders = try c.decodeIfPresent([String].self, forKey: .localProviders) ?? []
    }

    public var initials: String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        let letters = words.compactMap(\.first).map { String($0).uppercased() }.joined()
        return letters.isEmpty ? "?" : letters
    }
}

/// What a space uses for one provider, as picked in the space editor.
public enum AccountChoice: Hashable {
    /// The provider's shared sign-in, used by every space unless it overrides it (the default).
    case shared
    /// A separate account, shared only with spaces that pick it too.
    case existing(String)
    /// A new separate account, signed in to after saving.
    case new
    /// Not shared: sign-ins for this provider stay in this space.
    case local

    /// The choices that keep a space as it is: its exceptions; every other provider is shared.
    public static func current(in space: SpaceDef) -> [String: AccountChoice] {
        space.bindings.mapValues { $0 == SpaceDef.local ? AccountChoice.local : .existing($0) }
    }
}
