import Foundation
import WebKit

/// A one-time-code field (an SMS or authenticator code) the user or the page focused: one input,
/// or a row of single-character boxes that take one code between them.
public struct CodeFieldFocus {
    public let frame: PasswordFrame
    /// The field (a split field's first box) inside the frame's script; only meaningful to `fillCode`.
    public let fieldID: String
    /// 1 for an ordinary field, else the number of boxes (a code must have exactly that length).
    public let boxes: Int
    /// The longest code the field takes (its `maxlength`, or the number of boxes), if known.
    public let maxLength: Int?
    /// The field's box (all of a split field's boxes) in CSS pixels, relative to its frame.
    public let rect: CGRect
    /// The same in the web view's coordinates (flipped, top-left origin), for anchoring a popover.
    /// Nil in iframes, whose offset in the page isn't known.
    public let rectInWebView: CGRect?
    /// The user clicked the field or tabbed into it. Pages usually focus their code field by
    /// themselves; that reports false.
    public let isUserInitiated: Bool
    public let receivedAt: Date

    /// The host codes are looked up for: always the tab's top-level page, never an iframe's.
    public var pageHost: String? { OneTimeCodeBinding.pageHost(for: frame) }

    /// Whether the code fits: exactly as long as a split field, no longer than `maxLength`.
    public func accepts(_ code: String) -> Bool {
        guard OneTimeCodeBinding.isPlausibleCode(code) else { return false }
        if boxes > 1 { return code.count == boxes }
        if let maxLength { return code.count <= maxLength }
        return true
    }
}

/// Which codes may be offered in which field (2FASync's WebOTP binding, PROTOCOL.md §5, applied
/// conservatively on the browser side).
///
/// iSmith Agent's `recentCodes(forHost:)` already filters by the host it's given: a code bound to
/// a domain (the SMS's `@chase.com #123456` line) only for that host or a subdomain, and unbound
/// codes only in their first 2 minutes. The app always asks with the tab's **top-level** host
/// (`pageHost(for:)`), never an iframe's, so a page can't get another site's bound code by
/// framing that site. On top of that, `mayOffer` requires a bound code's domain to match **both**
/// the top-level host and the host of the frame holding the field: a bound code goes into a
/// frame only when the page and the frame are both that site. Unbound codes follow the top-level
/// page alone (they're offered for any page in their first 2 minutes anyway).
public enum OneTimeCodeBinding {
    /// Codes are offered on https pages, and on http only for loopback hosts (local testing):
    /// the same "potentially trustworthy" origins WebOTP allows.
    public static func pageHost(top: Origin?) -> String? {
        guard let top, !top.host.isEmpty else { return nil }
        switch top.scheme {
        case "https": return normalized(top.host)
        case "http" where isLoopback(top.host): return normalized(top.host)
        default: return nil
        }
    }

    /// The top-level page's host for a frame: the frame's own origin when it is the main frame,
    /// else the tab's page.
    public static func pageHost(for frame: PasswordFrame) -> String? {
        pageHost(top: frame.isMainFrame ? frame.origin : frame.topOrigin)
    }

    /// `host` is `domain` or a subdomain of it (`login.chase.com` for `chase.com`; not
    /// `evilchase.com`).
    public static func hostMatches(_ host: String, domain: String) -> Bool {
        let h = normalized(host), d = normalized(domain)
        guard !h.isEmpty, !d.isEmpty else { return false }
        return h == d || h.hasSuffix("." + d)
    }

    /// Whether a code bound to `domain` (nil: unbound) may be offered in a field of a frame on
    /// host `frameHost`, on a tab whose top-level page is `topHost`.
    public static func mayOffer(domain: String?, topHost: String, frameHost: String, isMainFrame: Bool) -> Bool {
        guard let domain else { return true }
        guard hostMatches(topHost, domain: domain) else { return false }
        return isMainFrame || hostMatches(frameHost, domain: domain)
    }

    /// The same for a focused field.
    public static func mayOffer(domain: String?, in focus: CodeFieldFocus) -> Bool {
        guard let top = focus.pageHost else { return false }
        return mayOffer(domain: domain, topHost: top, frameHost: focus.frame.origin.host, isMainFrame: focus.frame.isMainFrame)
    }

    /// 3 to 12 ASCII letters and digits, as 2FASync extracts them.
    public static func isPlausibleCode(_ code: String) -> Bool {
        (3...12).contains(code.count) && code.unicodeScalars.allSatisfy { $0.isASCII && CharacterSet.alphanumerics.contains($0) }
    }

    static func normalized(_ host: String) -> String {
        var h = host.lowercased()
        while h.hasSuffix(".") { h.removeLast() }
        return h
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = normalized(host)
        return h == "localhost" || h.hasSuffix(".localhost") || h == "127.0.0.1" || h == "::1" || h == "[::1]"
    }
}
