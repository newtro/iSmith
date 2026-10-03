import Foundation

/// A rough strength check for spotting weak saved passwords. It flags what attackers try first:
/// short passwords, common passwords and their decorated forms ("Password1!"), keyboard and
/// alphabet runs, one repeated character, the username or the site's name, and anything under
/// about 40 bits by character-set size.
public enum PasswordStrength: Int, Comparable, Sendable {
    case weak, fair, strong

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public static func evaluate(_ password: String, username: String = "", host: String = "") -> PasswordStrength {
        let chars = Array(password)
        if chars.count < 8 { return .weak }
        let lower = password.lowercased()
        if Set(chars).count <= 2 { return .weak }
        if commonPasswords.contains(lower) || commonPasswords.contains(core(of: lower)) { return .weak }
        if isRun(lower) || isRun(core(of: lower)) { return .weak }
        let user = username.lowercased().split(separator: "@").first.map(String.init) ?? ""
        if user.count >= 4, lower.contains(user) || core(of: lower) == user { return .weak }
        if let name = siteName(host), name.count >= 4, core(of: lower) == name { return .weak }

        let bits = entropyBits(password)
        if bits < 40 { return .weak }
        return bits < 70 ? .fair : .strong
    }

    /// Length times log2 of the character pool (lowercase, uppercase, digits, symbols, other).
    static func entropyBits(_ password: String) -> Double {
        var pool = 0
        if password.contains(where: { $0.isASCII && $0.isLowercase }) { pool += 26 }
        if password.contains(where: { $0.isASCII && $0.isUppercase }) { pool += 26 }
        if password.contains(where: { $0.isASCII && $0.isNumber }) { pool += 10 }
        if password.contains(where: { $0.isASCII && !$0.isLetter && !$0.isNumber }) { pool += 33 }
        if password.contains(where: { !$0.isASCII }) { pool += 100 }
        // Repeated characters add little: count distinct characters at full weight, repeats at half.
        let distinct = Set(password).count
        let effective = Double(distinct) + Double(password.count - distinct) / 2
        return effective * log2(Double(max(pool, 2)))
    }

    /// The password without a leading capital's case, and without trailing digits and symbols:
    /// "Password123!" → "password".
    static func core(of lower: String) -> String {
        var s = Substring(lower)
        while let last = s.last, !last.isLetter { s.removeLast() }
        while let first = s.first, !first.isLetter { s.removeFirst() }
        return String(s)
    }

    /// Every character one step from the last along the alphabet, digits or a keyboard row.
    static func isRun(_ s: String) -> Bool {
        guard s.count >= 4 else { return false }
        for row in ["abcdefghijklmnopqrstuvwxyz", "0123456789", "qwertyuiop", "asdfghjkl", "zxcvbnm", "1234567890"] {
            if row.contains(s) || String(row.reversed()).contains(s) { return true }
        }
        return false
    }

    static func siteName(_ host: String) -> String? {
        let parts = host.split(separator: ".")
        guard parts.count >= 2 else { return parts.first.map(String.init) }
        return String(parts[parts.count - 2])
    }

    /// The most common leaked passwords and base words (lowercase).
    static let commonPasswords: Set<String> = [
        "password", "passw0rd", "p@ssword", "p@ssw0rd", "123456", "12345678", "123456789", "1234567890",
        "qwerty", "qwertyuiop", "abc123", "111111", "1q2w3e4r", "1qaz2wsx", "letmein", "welcome",
        "monkey", "dragon", "football", "baseball", "iloveyou", "trustno1", "sunshine", "master",
        "shadow", "superman", "michael", "princess", "starwars", "whatever", "freedom", "login",
        "admin", "administrator", "changeme", "default", "secret", "access", "hello", "charlie",
        "donald", "batman", "jordan", "hunter", "ranger", "buster", "soccer", "hockey", "killer",
        "george", "andrew", "pepper", "summer", "winter", "spring", "autumn", "flower", "cookie",
        "chocolate", "computer", "internet", "samsung", "google", "apple", "microsoft", "zaq12wsx",
        "asdfgh", "asdfghjkl", "zxcvbnm", "qazwsx", "passport", "matrix", "mustang", "jennifer",
        "thomas", "jessica", "ashley", "daniel", "maggie", "loveme", "nicole", "biteme", "tigger",
        "orange", "banana", "purple", "yankees", "dallas", "austin", "thunder", "taylor", "matthew",
        "corvette", "ferrari", "mercedes", "harley", "q1w2e3r4", "q1w2e3r4t5", "aa123456", "qwe123",
        "password1", "welcome1", "admin123", "root", "toor", "test", "testing", "guest", "user",
    ]
}

/// Weak and reused passwords among saved logins.
public struct SecurityReport: Sendable {
    /// Logins whose password is weak.
    public let weak: Set<UUID>
    /// Groups of logins on different sites sharing one password, each group sorted by id.
    public let reused: [[UUID]]

    public init(logins: [Login]) {
        weak = Set(logins.filter {
            PasswordStrength.evaluate($0.password, username: $0.username, host: $0.origin.host) == .weak
        }.map(\.id))
        var byPassword: [String: [Login]] = [:]
        for login in logins where !login.password.isEmpty {
            byPassword[login.password, default: []].append(login)
        }
        reused = byPassword.values
            .filter { Set($0.map { $0.origin.site ?? $0.origin.host }).count > 1 }
            .map { $0.map(\.id).sorted { $0.uuidString < $1.uuidString } }
            .sorted { $0.first!.uuidString < $1.first!.uuidString }
    }

    public func isReused(_ id: UUID) -> Bool { reused.contains { $0.contains(id) } }
}
