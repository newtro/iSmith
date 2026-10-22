import Foundation

/// Classifies a site's PHP version against PHP2Shell (CVE-2026-109618, CVE-2026-109619, fixed
/// 2026-10-21) from the response headers a page load already carries: `X-Powered-By`, `Server`,
/// `Set-Cookie` (PHPSESSID), `X-Pingback`, `Link` (wp-json) and `.php` addresses.
public enum PHP2Shell {
    /// First patched release on each supported branch. Update when PHP ships further fixes.
    public static let fixedPatch: [String: Int] = ["8.2": 35, "8.3": 36, "8.4": 27, "8.5": 12]
    static let oldestSupported = (8, 2)
    static let newestKnown = (8, 5)

    public static let advisoryURL = URL(string: "https://www.cisa.gov/news-events/alerts/2026/10/21/critical-vulnerabilities-php-require-immediate-patching")!

    /// Worst last.
    public enum Level: Int, Comparable, Sendable {
        /// No sign of PHP. (Not `none`, which reads as `Optional.none` next to an optional.)
        case noPHP
        /// Every reported version includes the fix.
        case patched
        /// PHP, version hidden.
        case unknown
        /// A reported version predates the fix, but a Linux distribution may have backported it.
        case maybe
        /// A reported version predates the fix, with no sign of a distribution build.
        case vulnerable

        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

        /// Worth warning about before a password or card number goes in.
        public var warns: Bool { self >= .maybe }
    }

    public struct Version: Equatable, Sendable {
        public let raw: String
        public let major: Int
        public let minor: Int
        public let patch: Int?
        public let suffix: String
        /// The header it came from.
        public let source: String
        /// Looks like a distribution build, which may carry a backported fix.
        public let distro: Bool
    }

    public struct Evidence: Equatable, Sendable {
        public var versions: [Version] = []
        /// What showed PHP, as shown to the user ("X-Powered-By: PHP/8.3.20").
        public var signals: [String] = []
        public var distroHints: [String] = []
        public init() {}
        public var isEmpty: Bool { versions.isEmpty && signals.isEmpty }
    }

    public struct Verdict: Equatable, Sendable {
        public let level: Level
        public let version: String?
        public let reason: String
    }

    // MARK: - Detection

    private static let distro = regex(#"ubuntu|debian|deb\d|red ?hat|rhel|centos|rocky|almalinux|fedora|suse|amazon|\bel\d"#)
    /// Ubuntu and Debian packages always carry a version suffix (8.1.2-1ubuntu2.22,
    /// 8.2.29-1~deb12u1), so a bare version behind an "(Ubuntu)" or "(Debian)" web server is
    /// something else, such as the official Docker image (Debian based, built from upstream).
    /// Red Hat-family packages report bare versions.
    private static let serverDistro = regex(#"red ?hat|rhel|centos|rocky|almalinux|fedora|suse|amazon"#)
    /// Third-party repos that ship upstream releases unchanged rather than backports (Sury, Remi).
    private static let upstreamRepack = regex(#"sury|remi|\+0~\d{8}\.\d+\+"#)
    private static let phpToken = regex(#"\bPHP(?![a-z])(?:/(\d+)\.(\d+)(?:\.(\d+))?([^\s,;()]*))?"#)
    private static let phpSession = regex(#"(^|[\s;,])PHPSESSID="#)
    private static let phpEndpoint = regex(#"\.php\b"#)
    private static let wpJSON = regex(#"/wp-json/"#)

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static func matches(_ re: NSRegularExpression, _ s: String) -> Bool {
        re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }

    /// Every `PHP` or `PHP/x.y.z…` token in a header value; `version` is nil when PHP shows
    /// without one. More than one when Foundation joined repeated headers with ", ".
    static func parseTokens(_ value: String) -> [(raw: String, version: (Int, Int, Int?, String)?)] {
        phpToken.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap { m in
            guard let whole = Range(m.range, in: value) else { return nil }
            func group(_ i: Int) -> String? { Range(m.range(at: i), in: value).map { String(value[$0]) } }
            guard let major = group(1).flatMap(Int.init), let minor = group(2).flatMap(Int.init) else {
                return (String(value[whole]), nil)
            }
            return (String(value[whole]), (major, minor, group(3).flatMap(Int.init), group(4) ?? ""))
        }
    }

    /// The evidence in one response. `headers` in the order received; `url` is the response's.
    public static func analyze(headers: [(name: String, value: String)], url: URL?) -> Evidence {
        var found = Evidence()
        let server = headers.last { $0.name.lowercased() == "server" }?.value ?? ""
        for (name, value) in headers {
            switch name.lowercased() {
            case "x-powered-by", "server":
                let fromServer = name.lowercased() == "server"
                let tokens = parseTokens(value)
                if !tokens.isEmpty { found.signals.append("\(name): \(value)") }
                for token in tokens {
                    if let (major, minor, patch, suffix) = token.version {
                        let serverIsDistro = matches(fromServer ? distro : serverDistro, server)
                        let suffixIsDistro = matches(distro, suffix) && !matches(upstreamRepack, suffix)
                        found.versions.append(Version(raw: token.raw, major: major, minor: minor, patch: patch,
                                                      suffix: suffix, source: name, distro: suffixIsDistro || serverIsDistro))
                    }
                }
                if fromServer, matches(distro, value) { found.distroHints.append("\(name): \(value)") }
            case "set-cookie" where matches(phpSession, value):
                found.signals.append("Sets a PHPSESSID session cookie")
            case "x-pingback" where matches(phpEndpoint, value):
                found.signals.append("X-Pingback points at a .php endpoint (WordPress)")
            case "link" where matches(wpJSON, value):
                found.signals.append("Link header advertises wp-json (WordPress)")
            default:
                break
            }
        }
        if let path = url?.path, path.lowercased().hasSuffix(".php") {
            found.signals.append("URL path ends in .php")
        }
        return found
    }

    /// One response's headers, as `HTTPURLResponse.allHeaderFields` gives them. WebKit's
    /// navigation responses leave out Set-Cookie, so PHPSESSID never shows through this path.
    public static func analyze(_ response: HTTPURLResponse) -> Evidence {
        let headers = response.allHeaderFields.compactMap { key, value -> (name: String, value: String)? in
            guard let name = key as? String else { return nil }
            return (name, "\(value)")
        }
        return analyze(headers: headers, url: response.url)
    }

    /// A page can load many frames; evidence per page is capped.
    static let maxItems = 10

    /// Folds one response's evidence into a page's. The cap keeps the worst versions.
    public static func merge(_ acc: Evidence, _ next: Evidence) -> Evidence {
        var out = acc
        let key = { (v: Version) in "\(v.source)|\(v.raw)|\(v.distro)" }
        var seen = Set(out.versions.map(key))
        for v in next.versions where seen.insert(key(v)).inserted { out.versions.append(v) }
        for s in next.signals where !out.signals.contains(s) { out.signals.append(s) }
        for s in next.distroHints where !out.distroHints.contains(s) { out.distroHints.append(s) }
        if out.versions.count > maxItems {
            out.versions = out.versions.enumerated()
                .sorted { a, b in
                    let (ra, rb) = (classify(a.element).level, classify(b.element).level)
                    return ra != rb ? ra > rb : a.offset < b.offset
                }
                .prefix(maxItems)
                .sorted { $0.offset < $1.offset }
                .map(\.element)
        }
        out.signals = Array(out.signals.prefix(maxItems))
        out.distroHints = Array(out.distroHints.prefix(maxItems))
        return out
    }

    // MARK: - Classification

    static func classify(_ v: Version) -> Verdict {
        let version = "\(v.major).\(v.minor)\(v.patch.map { ".\($0)" } ?? "")\(v.suffix)"
        let branch = "\(v.major).\(v.minor)"
        let detail: String
        if (v.major, v.minor) < oldestSupported {
            detail = "PHP \(version) is end-of-life. PHP has released no fix for this branch."
        } else if (v.major, v.minor) > newestKnown {
            return Verdict(level: .patched, version: version, reason: "PHP \(version) is newer than every branch in the advisory.")
        } else if v.patch == nil {
            return Verdict(level: .unknown, version: version,
                           reason: "This site reports PHP \(branch) without a patch number, so its patch status can't be determined.")
        } else if let patch = v.patch, let fixed = fixedPatch[branch], patch < fixed {
            detail = "PHP \(version) is older than the fixed release \(branch).\(fixed)."
        } else {
            return Verdict(level: .patched, version: version, reason: "PHP \(version) includes the PHP2Shell fix.")
        }
        if v.distro {
            return Verdict(level: .maybe, version: version,
                           reason: "\(detail) The server looks like a Linux distribution build, and distributions often backport fixes without changing the version number, so it may be patched.")
        }
        return Verdict(level: .vulnerable, version: version,
                       reason: "\(detail) The server is likely exposed to PHP2Shell, unless its operating system vendor backported the fix without changing the version.")
    }

    /// With several versions (the page and a frame), the worst wins.
    public static func classify(_ evidence: Evidence) -> Verdict {
        if evidence.isEmpty {
            return Verdict(level: .noPHP, version: nil, reason: "No sign of PHP in this page's responses.")
        }
        if evidence.versions.isEmpty {
            return Verdict(level: .unknown, version: nil,
                           reason: "This site runs PHP but hides its version, so its patch status can't be seen from the browser.")
        }
        let verdicts = evidence.versions.map(classify)
        return verdicts.dropFirst().reduce(verdicts[0]) { worst, v in v.level > worst.level ? v : worst }
    }
}
