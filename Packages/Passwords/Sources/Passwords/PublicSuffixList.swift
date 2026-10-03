import Foundation

/// The Mozilla Public Suffix List, used to find a host's registrable domain ("eTLD+1"): the part
/// a single owner controls. `mail.google.com` and `accounts.google.com` share `google.com`, but
/// `alice.github.io` and `bob.github.io` don't share anything, because `github.io` is a public
/// suffix. The list ships as a resource (`Resources/public_suffix_list.dat`); refreshing it is a
/// file replacement.
public struct PublicSuffixList: Sendable {
    private let rules: Set<String>
    /// "*.ck" is stored as "ck": every direct child of these is a public suffix.
    private let wildcardParents: Set<String>
    /// "!www.ck" is stored as "www.ck": a registrable domain despite a wildcard above it.
    private let exceptions: Set<String>

    public static let shared: PublicSuffixList = {
        guard let url = Bundle.module.url(forResource: "public_suffix_list", withExtension: "dat"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            // Without the list every host is matched exactly (registrableDomain is only ever
            // asked of hosts with a known suffix rule), which is safe, just less convenient.
            return PublicSuffixList(text: "")
        }
        return PublicSuffixList(text: text)
    }()

    /// Parses the list's text format: one rule per line, `//` comments, `*.` wildcards and `!`
    /// exceptions. Unicode rules are converted to their punycode (`xn--`) form, which is how hosts
    /// arrive from WebKit.
    public init(text: String) {
        var rules = Set<String>(), wildcards = Set<String>(), exceptions = Set<String>()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
            if line.isEmpty || line.hasPrefix("//") { continue }
            if line.hasPrefix("!") {
                if let rule = Punycode.asciiHost(String(line.dropFirst())) { exceptions.insert(rule) }
            } else if line.hasPrefix("*.") {
                if let rule = Punycode.asciiHost(String(line.dropFirst(2))) { wildcards.insert(rule) }
            } else if let rule = Punycode.asciiHost(line) {
                rules.insert(rule)
            }
        }
        self.rules = rules
        self.wildcardParents = wildcards
        self.exceptions = exceptions
    }

    public var isEmpty: Bool { rules.isEmpty && wildcardParents.isEmpty }

    /// The public suffix of a normalized (lowercase, ASCII) host, by the list's algorithm: the
    /// longest matching rule wins, exceptions beat wildcards, and an unlisted TLD is a suffix.
    public func publicSuffix(of host: String) -> String {
        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard !labels.isEmpty else { return host }
        for i in labels.indices {
            let candidate = labels[i...].joined(separator: ".")
            if exceptions.contains(candidate) {
                return labels[(i + 1)...].joined(separator: ".")
            }
            if rules.contains(candidate) { return candidate }
            if i + 1 < labels.count, wildcardParents.contains(labels[(i + 1)...].joined(separator: ".")) {
                return candidate
            }
        }
        return labels[labels.count - 1]
    }

    /// The registrable domain (public suffix plus one label), or nil when the host is itself a
    /// public suffix, such as `github.io` or `co.uk`.
    public func registrableDomain(of host: String) -> String? {
        if isEmpty { return nil }
        let suffix = publicSuffix(of: host)
        guard host.count > suffix.count, host.hasSuffix("." + suffix) else { return nil }
        let rest = host.dropLast(suffix.count + 1)
        guard let label = rest.split(separator: ".", omittingEmptySubsequences: false).last,
              !label.isEmpty else { return nil }
        return "\(label).\(suffix)"
    }
}

/// IDNA host conversion: lowercases a host and encodes each non-ASCII label as punycode
/// (RFC 3492), so `Bücher.de` becomes `xn--bcher-kva.de`.
enum Punycode {
    /// The ASCII form of a host, or nil when a label can't be encoded or is empty.
    static func asciiHost(_ host: String) -> String? {
        let lowered = host.precomposedStringWithCanonicalMapping.lowercased()
        var out: [String] = []
        for label in lowered.split(separator: ".", omittingEmptySubsequences: false) {
            if label.unicodeScalars.allSatisfy(\.isASCII) {
                out.append(String(label))
            } else {
                guard let encoded = encode(String(label)) else { return nil }
                out.append("xn--" + encoded)
            }
        }
        let result = out.joined(separator: ".")
        return result.isEmpty ? nil : result
    }

    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700
    private static let initialBias = 72, initialN = 0x80

    private static func adapt(_ delta: Int, _ numPoints: Int, _ first: Bool) -> Int {
        var delta = first ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }

    private static func digit(_ d: Int) -> Character {
        Character(UnicodeScalar(UInt8(d < 26 ? d + 97 : d + 22)))
    }

    /// RFC 3492 encoding of one label (without the `xn--` prefix).
    static func encode(_ label: String) -> String? {
        let input = label.unicodeScalars.map { Int($0.value) }
        var output = String(input.filter { $0 < 0x80 }.map { Character(UnicodeScalar(UInt8($0))) })
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append("-") }
        var n = initialN, delta = 0, bias = initialBias
        while handled < input.count {
            guard let m = input.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = m
            for c in input {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, handled + 1, handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return output
    }
}
