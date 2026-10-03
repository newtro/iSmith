import Foundation

/// A pattern for web addresses, as a routing rule holds it:
///
/// - `dev.azure.com`: that host (any path);
/// - `dev.azure.com/contoso-dev`: that host, under that path (`/contoso-dev`,
///   `/contoso-dev/Storefront/_boards`, but not `/contoso-dev2`);
/// - `*.fabrikam.com`: the domain and every subdomain (`fabrikam.com`,
///   `files.fabrikam.com`), optionally with a path.
///
/// A scheme (`https://`) and a trailing `/*` or `*` are accepted and dropped. Hosts and paths
/// compare without case, and `www.` is ignored on both sides, so `github.com` and
/// `www.github.com` are the same. A port, if given, must match. Only http and https addresses
/// match.
public struct URLPattern: Hashable, Codable, CustomStringConvertible, Sendable {
    /// Lowercased, without `www.`, a trailing dot or the `*.` prefix.
    public let host: String
    /// `*.`: the host and all its subdomains.
    public let includesSubdomains: Bool
    public let port: Int?
    /// Lowercased, decoded, starting with `/` and without a trailing `/`; empty for any path.
    public let pathPrefix: String

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case empty
        case badHost
        case misplacedWildcard
        case badPort

        public var description: String {
            switch self {
            case .empty: return "Type an address, such as dev.azure.com/contoso-dev."
            case .badHost: return "That isn't a host name, such as dev.azure.com or *.sharepoint.com."
            case .misplacedWildcard: return "A * can only start the host (*.example.com) or end the address (example.com/*)."
            case .badPort: return "The port after : must be a number."
            }
        }
    }

    public init(host: String, includesSubdomains: Bool = false, port: Int? = nil, pathPrefix: String = "") {
        self.host = Self.normalizedHost(host)
        self.includesSubdomains = includesSubdomains
        self.port = port
        self.pathPrefix = Self.normalizedPath(pathPrefix)
    }

    /// Parses what someone typed in the rule editor.
    public init(parsing input: String) throws {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        if let scheme = text.range(of: "://") { text = String(text[scheme.upperBound...]) }
        // A query or fragment means nothing to a rule.
        if let cut = text.firstIndex(where: { $0 == "?" || $0 == "#" }) { text = String(text[..<cut]) }
        while text.hasSuffix("/*") || text.hasSuffix("/") {
            text.removeLast(text.hasSuffix("/*") ? 2 : 1)
        }
        let slash = text.firstIndex(of: "/")
        var hostPart = String(text[..<(slash ?? text.endIndex)])
        let path = slash.map { String(text[$0...]) } ?? ""
        guard !path.contains("*") else { throw ParseError.misplacedWildcard }
        if hostPart.hasPrefix("*.") {
            hostPart.removeFirst(2)
            includesSubdomains = true
        } else {
            includesSubdomains = false
        }
        guard !hostPart.contains("*") else { throw ParseError.misplacedWildcard }
        if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
        var parsedPort: Int?
        if let colon = hostPart.firstIndex(of: ":") {
            let digits = hostPart[hostPart.index(after: colon)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isASCII), let p = Int(digits), (1...65535).contains(p) else {
                throw ParseError.badPort
            }
            parsedPort = p
            hostPart = String(hostPart[..<colon])
        }
        let host = Self.normalizedHost(hostPart)
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard !host.isEmpty, host.allSatisfy({ allowed.contains($0) }), !host.hasPrefix("."), !host.contains("..") else {
            throw ParseError.badHost
        }
        self.host = host
        port = parsedPort
        pathPrefix = Self.normalizedPath(path)
    }

    /// The pattern as the editor shows it: `*.fabrikam.com`, `dev.azure.com/contoso-dev`.
    public var description: String {
        (includesSubdomains ? "*." : "") + host + (port.map { ":\($0)" } ?? "") + pathPrefix
    }

    public func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let rawHost = url.host, !rawHost.isEmpty else { return false }
        let host = Self.normalizedHost(rawHost)
        if includesSubdomains {
            guard host == self.host || host.hasSuffix("." + self.host) else { return false }
        } else {
            guard host == self.host else { return false }
        }
        if let port {
            guard (url.port ?? (scheme == "https" ? 443 : 80)) == port else { return false }
        }
        return Self.path(Self.normalizedPath(url.path), isUnder: pathPrefix)
    }

    static func path(_ path: String, isUnder prefix: String) -> Bool {
        prefix.isEmpty || path == prefix || path.hasPrefix(prefix + "/")
    }

    /// Lowercased, without a trailing dot or a leading `www.`.
    public static func normalizedHost(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    static func normalizedPath(_ path: String) -> String {
        var p = (path.removingPercentEncoding ?? path).lowercased()
        while p.hasSuffix("/") { p.removeLast() }
        if !p.isEmpty, !p.hasPrefix("/") { p = "/" + p }
        return p
    }

    // Codable as the editor's text, so routing.json stays readable.
    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        try self.init(parsing: text)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}
