import Foundation

/// A web origin that logins are saved under and matched against: scheme, host and port.
///
/// Only `http` and `https` origins exist here. Hosts are normalized: lowercase, punycode for
/// international names, no trailing dot, and IPv6 addresses without brackets. The port is the
/// effective port, so `https://example.com` and `https://example.com:443` are the same origin.
///
/// ## Matching rules
///
/// A login saved for origin S is offered on a frame whose origin is P when:
///
/// 1. **Same scheme.** Never across schemes: an `https` login is not offered to `http`, and an
///    `http` login is not offered to `https`.
/// 2. **Same effective port.** `https://example.com` (443) and `https://example.com:8443` don't
///    match, and neither do `localhost:3000` and `localhost:8080`.
/// 3. Then either
///    - **exact**: the hosts are equal; or
///    - **same site**: both hosts have the same registrable domain under the Public Suffix List
///      (`accounts.example.com` and `www.example.com` share `example.com`). Only for `https`
///      domain names: `http` origins (a network attacker can invent any `http` subdomain), IP
///      addresses, single-label hosts (`localhost`, `intranet`), hosts that are themselves
///      public suffixes (`github.io`), and hosts under a multi-tenant service that isn't on the
///      list (`Origin.exactOnlySites`: `okta.com`, `sharepoint.com`, `atlassian.net`, …, where
///      each subdomain is a different customer) match exactly or not at all. Two hosts under a
///      public suffix (`alice.github.io`, `bob.github.io`) never match each other.
///
/// Exact matches are listed before same-site matches. A same-site match is only ever filled
/// after the user picks it in the popover, which shows its host (`fill(_:into:allowSameSite:)`);
/// ⌘\ and preselection use exact matches only. Matching is always against the origin of
/// the frame that holds the form (`WKFrameInfo.securityOrigin`), never the tab's address, so a
/// cross-origin iframe only sees logins for its own origin. Opaque origins (sandboxed frames,
/// `data:`, `file:`) have no `Origin` and match nothing.
public struct Origin: Hashable, Sendable, Comparable, CustomStringConvertible {
    public let scheme: String
    public let host: String
    public let port: Int

    /// Builds a normalized origin; nil for anything but a valid http or https host.
    /// A `port` of nil or 0 means the scheme's default.
    public init?(scheme: String, host: String, port: Int? = nil) {
        let scheme = scheme.lowercased()
        guard let defaultPort = Self.defaultPorts[scheme] else { return nil }
        guard let host = Self.normalizeHost(host) else { return nil }
        let port = (port ?? 0) == 0 ? defaultPort : port!
        guard (1...65535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    /// The origin of a URL, ignoring user info, path, query and fragment.
    public init?(url: URL) {
        guard let scheme = url.scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let host = components.host, !host.isEmpty else { return nil }
        self.init(scheme: scheme, host: host, port: components.port)
    }

    /// Parses `scheme://host[:port]` (a path, if any, is ignored).
    public init?(string: String) {
        guard let url = URL(string: string) else { return nil }
        self.init(url: url)
    }

    static let defaultPorts = ["http": 80, "https": 443]

    public var isDefaultPort: Bool { Self.defaultPorts[scheme] == port }

    /// The origin as `window.location.origin` serializes it: `https://example.com`,
    /// `http://localhost:8080`, `http://[::1]:3000`.
    public var serialized: String {
        let h = isIPv6 ? "[\(host)]" : host
        return isDefaultPort ? "\(scheme)://\(h)" : "\(scheme)://\(h):\(port)"
    }

    public var description: String { serialized }

    public var isIPv6: Bool { host.contains(":") }

    public var isIPAddress: Bool {
        if isIPv6 { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { UInt8($0) != nil }
    }

    /// The registrable domain used for same-site matching, or nil for hosts that only match
    /// exactly: IP addresses, single-label hosts, and hosts that are public suffixes.
    public var site: String? { site(using: .shared) }

    func site(using list: PublicSuffixList) -> String? {
        guard !isIPAddress, host.contains(".") else { return nil }
        return list.registrableDomain(of: host)
    }

    /// Registrable domains whose subdomains belong to different customers but that the Public
    /// Suffix List doesn't list: hosts under these only match exactly, so one tenant's login is
    /// never offered on another tenant's page.
    public static let exactOnlySites: Set<String> = [
        "okta.com", "oktapreview.com", "okta-emea.com", "okta-gov.com", "auth0.com", "onelogin.com",
        "sharepoint.com", "sharepoint-df.com", "visualstudio.com", "dynamics.com", "powerapps.com",
        "atlassian.net", "jira.com", "zendesk.com", "freshdesk.com", "freshservice.com",
        "salesforce.com", "force.com", "site.com", "service-now.com", "servicenowservices.com",
        "slack.com", "zoom.us", "webex.com", "box.com", "myshopify.com", "wordpress.com",
        "tumblr.com", "wixsite.com", "squarespace.com", "notion.site", "bamboohr.com",
        "workday.com", "myworkday.com", "smartsheet.com", "kintone.com", "zohodesk.com",
    ]

    /// The registrable domain used for same-site matching, or nil when this origin only matches
    /// exactly.
    func sameSiteKey(using list: PublicSuffixList) -> String? {
        guard scheme == "https", let site = site(using: list), !Self.exactOnlySites.contains(site) else { return nil }
        return site
    }

    /// How a login saved under `saved` matches a form in a frame of origin `page`, or nil when it
    /// must not be offered there. See the type's documentation for the rules.
    public static func match(saved: Origin, page: Origin) -> MatchKind? {
        match(saved: saved, page: page, using: .shared)
    }

    static func match(saved: Origin, page: Origin, using list: PublicSuffixList) -> MatchKind? {
        guard saved.scheme == page.scheme, saved.port == page.port else { return nil }
        if saved.host == page.host { return .exact }
        guard let a = saved.sameSiteKey(using: list), let b = page.sameSiteKey(using: list), a == b else { return nil }
        return .sameSite
    }

    public static func < (lhs: Origin, rhs: Origin) -> Bool { lhs.serialized < rhs.serialized }

    /// Lowercase ASCII host without a trailing dot or IPv6 brackets, or nil if it isn't a host.
    static func normalizeHost(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespaces)
        if host.hasPrefix("[") && host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if host.contains(":") {
            // IPv6: hex digits, colons and dots (an embedded IPv4) only.
            let lowered = host.lowercased()
            guard lowered.allSatisfy({ $0.isHexDigit || $0 == ":" || $0 == "." }) else { return nil }
            return lowered
        }
        while host.hasSuffix(".") { host.removeLast() }
        // URLComponents may hand back percent-encoded international names.
        if host.contains("%") { host = host.removingPercentEncoding ?? host }
        guard let ascii = Punycode.asciiHost(host), !ascii.isEmpty, ascii.count <= 253 else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard ascii.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard !ascii.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty) else {
            return nil
        }
        return ascii
    }
}

/// How well a saved login's origin fits the page.
public enum MatchKind: Int, Comparable, Sendable {
    /// Same scheme, host and port.
    case exact = 0
    /// Same scheme and port, another host with the same registrable domain.
    case sameSite = 1

    public static func < (lhs: MatchKind, rhs: MatchKind) -> Bool { lhs.rawValue < rhs.rawValue }
}
