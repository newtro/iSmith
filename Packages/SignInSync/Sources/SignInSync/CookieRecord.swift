import Foundation

/// A cookie in a form that survives a JSON round trip and compares by value.
public struct CookieRecord: Codable, Hashable {
    public var name: String
    public var value: String
    public var domain: String
    public var path: String
    public var expires: Date?
    public var secure: Bool
    public var httpOnly: Bool
    public var sameSite: String?

    public var key: String { "\(domain.lowercased())|\(path)|\(name)" }
    public var isExpired: Bool { expires.map { $0 < Date() } ?? false }

    public init(_ cookie: HTTPCookie) {
        name = cookie.name
        value = cookie.value
        domain = cookie.domain
        path = cookie.path
        // WebKit stores whole seconds; truncating keeps a re-read cookie equal to the original.
        expires = cookie.expiresDate.map { Date(timeIntervalSince1970: floor($0.timeIntervalSince1970)) }
        secure = cookie.isSecure
        httpOnly = cookie.isHTTPOnly
        sameSite = cookie.sameSitePolicy?.rawValue
    }

    public var cookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { props[.expires] = expires }
        if secure { props[.secure] = "TRUE" }
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { props[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: props)
    }
}
