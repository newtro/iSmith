import Foundation

/// What a new-password field allows, read from the page: `minlength`, `maxlength`, and the
/// `passwordrules` attribute (https://github.com/whatwg/html/issues/3518, used by Safari).
public struct PasswordRequirements: Hashable, Sendable {
    public var minLength: Int?
    public var maxLength: Int?
    /// The raw `passwordrules` value, e.g. `required: upper; required: digit; maxlength: 16;`.
    public var rules: String?

    public init(minLength: Int? = nil, maxLength: Int? = nil, rules: String? = nil) {
        self.minLength = minLength
        self.maxLength = maxLength
        self.rules = rules
    }
}

/// Strong passwords for signup and change-password forms, from the system's cryptographically
/// secure random source (`SystemRandomNumberGenerator`, which is `arc4random` on macOS).
///
/// The default looks like Safari's: three groups of six letters and digits joined by hyphens
/// (`xKfr4w-Pmdq7z-hTbn2c`), with at least one capital and one digit and no look-alike
/// characters (about 100 bits). When the page's length limits or `passwordrules` don't allow
/// that shape, it falls back to random characters from what the rules allow, with one of each
/// required class.
///
/// The page's numbers are untrusted: lengths are kept within 4...128 characters
/// (`lengthLimits`), so a field with `minlength=2000000000` can't stall or exhaust the app, and
/// only printable ASCII is ever used.
public enum PasswordGenerator {
    /// The shortest and longest password ever generated, whatever the page asks for.
    public static let lengthLimits = 4...128

    static let lower = Array("abcdefghijkmnpqrstuvwxyz")      // no l, o
    static let upper = Array("ABCDEFGHJKLMNPQRSTUVWXYZ")      // no I, O
    static let digits = Array("23456789")                     // no 0, 1
    static let special = Array("-~!@#$%^&*_+=|(){}[]:;<>,.?/")

    public static func generate(_ requirements: PasswordRequirements = PasswordRequirements()) -> String {
        var rng = SystemRandomNumberGenerator()
        return generate(requirements, using: &rng)
    }

    static func generate<R: RandomNumberGenerator>(_ requirements: PasswordRequirements, using rng: inout R) -> String {
        let rules = Rules(requirements)
        let length = rules.length
        if rules.allowsDefaultShape, length == 20 {
            for _ in 0..<100 {
                let password = defaultShape(using: &rng)
                if rules.accepts(password) { return password }
            }
        }
        for _ in 0..<200 {
            let password = random(rules, length: length, using: &rng)
            if rules.accepts(password) { return password }
        }
        // The rules contradict themselves (say, max-consecutive 1 with one allowed character):
        // the closest thing that satisfies them is still random.
        return random(rules, length: length, using: &rng)
    }

    static func defaultShape<R: RandomNumberGenerator>(using rng: inout R) -> String {
        let pool = lower + upper + digits
        while true {
            let groups = (0..<3).map { _ in String((0..<6).map { _ in pool.randomElement(using: &rng)! }) }
            let joined = groups.joined(separator: "-")
            if joined.contains(where: { upper.contains($0) }), joined.contains(where: { digits.contains($0) }),
               joined.contains(where: { lower.contains($0) }) {
                return joined
            }
        }
    }

    static func random<R: RandomNumberGenerator>(_ rules: Rules, length: Int, using rng: inout R) -> String {
        var chars: [Character] = rules.required.map { $0.randomElement(using: &rng)! }
        let pool = rules.allowed
        while chars.count < length { chars.append(pool.randomElement(using: &rng)!) }
        chars.shuffle(using: &rng)
        return String(chars.prefix(max(length, min(rules.required.count, PasswordGenerator.lengthLimits.upperBound))))
    }

    /// The parsed limits and rules for one field.
    struct Rules {
        var minLength = 0
        var maxLength = Int.max
        var required: [[Character]] = []
        var allowed: [Character] = []
        var maxConsecutive: Int?

        init(_ requirements: PasswordRequirements) {
            var allowedSets: [[Character]] = []
            for property in (requirements.rules ?? "").split(separator: ";") {
                let parts = property.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                guard parts.count == 2 else { continue }
                let (name, value) = (parts[0], parts[1])
                switch name {
                case "required": required.append(Self.characters(value))
                case "allowed": allowedSets.append(Self.characters(value))
                case "max-consecutive": maxConsecutive = Int(value).flatMap { $0 > 0 ? $0 : nil }
                case "minlength": minLength = max(minLength, Int(value) ?? 0)
                case "maxlength": if let v = Int(value), v > 0 { maxLength = min(maxLength, v) }
                default: break
                }
            }
            if let m = requirements.minLength, m > 0 { minLength = max(minLength, m) }
            if let m = requirements.maxLength, m > 0 { maxLength = min(maxLength, m) }
            required = Array(required.filter { !$0.isEmpty }.prefix(8))
            if required.isEmpty && allowedSets.isEmpty {
                required = [PasswordGenerator.lower, PasswordGenerator.upper, PasswordGenerator.digits]
                allowedSets = [PasswordGenerator.lower + PasswordGenerator.upper + PasswordGenerator.digits + ["-"]]
            }
            var seen = Set<Character>()
            allowed = (allowedSets.flatMap { $0 } + required.flatMap { $0 }).filter { seen.insert($0).inserted }
            if allowed.isEmpty { allowed = PasswordGenerator.lower + PasswordGenerator.upper + PasswordGenerator.digits }
        }

        /// 20 characters unless the field needs more or allows fewer, within `lengthLimits`.
        var length: Int {
            var n = 20
            if minLength > n { n = minLength }
            if maxLength < n { n = maxLength }
            return min(max(n, PasswordGenerator.lengthLimits.lowerBound), PasswordGenerator.lengthLimits.upperBound)
        }

        /// Whether hyphen-joined letters and digits fit: `-`, letters and digits are all allowed,
        /// and every required class is one of those.
        var allowsDefaultShape: Bool {
            let shape = Set(PasswordGenerator.lower + PasswordGenerator.upper + PasswordGenerator.digits + ["-"])
            let allowedSet = Set(allowed)
            return shape.isSubset(of: allowedSet)
                && required.allSatisfy { !Set($0).isDisjoint(with: shape) }
        }

        func accepts(_ password: String) -> Bool {
            let chars = Array(password)
            guard chars.count >= min(minLength, length), chars.count <= max(maxLength, length) else { return false }
            let allowedSet = Set(allowed)
            guard chars.allSatisfy({ allowedSet.contains($0) }) else { return false }
            for set in required where !chars.contains(where: { set.contains($0) }) { return false }
            if let maxConsecutive {
                var run = 1
                for i in chars.indices.dropFirst() {
                    run = chars[i] == chars[i - 1] ? run + 1 : 1
                    if run > maxConsecutive { return false }
                }
            }
            return true
        }

        /// A comma-separated list of classes (`upper`, `lower`, `digit`, `special`,
        /// `ascii-printable`, `unicode`) and bracketed literals (`[-_!]`).
        static func characters(_ value: String) -> [Character] {
            var out: [Character] = []
            var rest = Substring(value)
            while !rest.isEmpty {
                rest = rest.drop { $0 == "," || $0 == " " }
                if rest.first == "[" {
                    let body = rest.dropFirst().prefix { $0 != "]" }
                    // Printable ASCII only: no control characters, spaces or quotes.
                    out += body.filter {
                        guard let a = $0.asciiValue else { return false }
                        return (0x21...0x7E).contains(a) && $0 != "\"" && $0 != "'" && $0 != "`"
                    }
                    rest = rest.dropFirst(body.count + 2)
                    continue
                }
                let word = rest.prefix { $0 != "," }
                rest = rest.dropFirst(word.count)
                switch word.trimmingCharacters(in: .whitespaces) {
                case "upper": out += PasswordGenerator.upper
                case "lower": out += PasswordGenerator.lower
                case "digit": out += PasswordGenerator.digits
                case "special": out += PasswordGenerator.special
                case "ascii-printable", "unicode":
                    out += PasswordGenerator.lower + PasswordGenerator.upper + PasswordGenerator.digits + PasswordGenerator.special
                default: break
                }
            }
            return out
        }
    }
}
