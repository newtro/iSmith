import Foundation

/// A cookie in a form that survives a JSON round trip and compares by value.
struct CookieRecord: Codable, Hashable {
    var name: String
    var value: String
    var domain: String
    var path: String
    var expires: Date?
    var secure: Bool
    var httpOnly: Bool
    var sameSite: String?

    var key: String { "\(domain.lowercased())|\(path)|\(name)" }
    var isExpired: Bool { expires.map { $0 < Date() } ?? false }

    init(_ cookie: HTTPCookie) {
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

    var cookie: HTTPCookie? {
        var props: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if let expires { props[.expires] = expires }
        if secure { props[.secure] = "TRUE" }
        if httpOnly { props[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
        if let sameSite { props[.sameSitePolicy] = sameSite }
        return HTTPCookie(properties: props)
    }
}

/// Provider cookies per account, saved to Application Support.
///
/// Spike only: stored as plain JSON with owner-only permissions, the same protection WebKit's own
/// cookie files get. The real vault encrypts with a Keychain-held key (see DESIGN.md).
@MainActor
final class Vault: ObservableObject {
    struct Entry: Codable {
        var cookies: [CookieRecord]
        var updated: Date
    }

    @Published private(set) var entries: [String: Entry] = [:]
    let fileURL: URL

    init() {
        fileURL = AppPaths.dir.appendingPathComponent("vault.json")
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    /// nil means the account has never been seen; an empty array means it is signed out.
    func records(for accountID: String) -> [CookieRecord]? { entries[accountID]?.cookies }

    func set(_ records: [CookieRecord], for accountID: String) {
        entries[accountID] = Entry(cookies: records.sorted { $0.key < $1.key }, updated: Date())
        save()
    }

    func remove(_ accountID: String) {
        entries[accountID] = nil
        save()
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: fileURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            NSLog("iSmith vault save failed: \(error)")
        }
    }
}
