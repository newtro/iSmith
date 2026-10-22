import AppKit
import SiteCheck
import SwiftUI
import WebKit

/// The PHP2Shell check (CVE-2026-109618, CVE-2026-109619): what a page's own responses say about
/// its server's PHP version. iSmith never sends a request for it; it reads the headers WebKit
/// already received for the page and its frames. A warning shows in the address bar, and a bar
/// over the page the first time a password or card field gets focus on a warned site.
struct PHPCheck: Equatable {
    /// scheme://host[:port] of the page the evidence belongs to.
    let origin: String
    let evidence: PHP2Shell.Evidence
    let verdict: PHP2Shell.Verdict

    init(origin: String, evidence: PHP2Shell.Evidence) {
        self.origin = origin
        self.evidence = evidence
        verdict = PHP2Shell.classify(evidence)
    }

    static let enabledKey = "php2shellCheck"
    static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// The site settings' origin key, so ports and case compare the same way everywhere.
    static func origin(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return WKSecurityOrigin.key(scheme: scheme, host: host, port: url.port ?? 0)
    }

    static func origin(of origin: WKSecurityOrigin) -> String { origin.originKey }

    static func withoutFragment(_ url: URL?) -> String? {
        guard let url else { return nil }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
        parts?.fragment = nil
        return parts?.string ?? url.absoluteString
    }
}

/// Per tab: main-frame responses waiting for their navigation to commit (so a download or a 204
/// never replaces the page on screen), and the last check per origin for pages that commit
/// without a response (back/forward cache).
struct PHPCheckHistory {
    var pending: [(url: String, evidence: PHP2Shell.Evidence)] = []
    var seen: [String: PHPCheck] = [:]
    var seenOrder: [String] = []

    mutating func remember(_ check: PHPCheck) {
        seen[check.origin] = check
        seenOrder.removeAll { $0 == check.origin }
        seenOrder.append(check.origin)
        while seenOrder.count > 20 { seen[seenOrder.removeFirst()] = nil }
    }
}

extension BrowserState {
    /// Called for every navigation response. Main frame: held until it commits. A frame from the
    /// page's own origin adds what it shows (an embedded admin page can reveal PHP the page hides).
    /// Unlike the browser extension, fetch/XHR responses aren't seen: WebKit gives the app no
    /// headers for subresources.
    func phpCheckResponse(_ navigationResponse: WKNavigationResponse, in webView: WKWebView) {
        guard PHPCheck.enabled, let http = navigationResponse.response as? HTTPURLResponse,
              let (_, _, tab) = owner(of: webView) else { return }
        let found = PHP2Shell.analyze(http)
        if navigationResponse.isForMainFrame {
            guard let url = PHPCheck.withoutFragment(http.url) else { return }
            tab.phpHistory.pending.append((url, found))
            tab.phpHistory.pending = Array(tab.phpHistory.pending.suffix(8))
        } else if !found.isEmpty, let check = tab.phpCheck, PHPCheck.origin(of: http.url) == check.origin {
            let merged = PHPCheck(origin: check.origin, evidence: PHP2Shell.merge(check.evidence, found))
            if merged != check {
                tab.phpCheck = merged
                tab.phpHistory.remember(merged)
            }
        }
    }

    /// A main-frame response became a download: it never shows, so it never becomes the check.
    func phpCheckDownloaded(_ navigationResponse: WKNavigationResponse, in webView: WKWebView) {
        guard navigationResponse.isForMainFrame, let (_, _, tab) = owner(of: webView),
              let url = PHPCheck.withoutFragment(navigationResponse.response.url) else { return }
        tab.phpHistory.pending.removeAll { $0.url == url }
    }

    /// The main frame committed: the response for its address becomes the tab's check.
    func phpCheckCommitted(_ webView: WKWebView, tab: Tab) {
        tab.phpWarned = false
        guard PHPCheck.enabled, let origin = PHPCheck.origin(of: webView.url),
              let url = PHPCheck.withoutFragment(webView.url) else {
            tab.phpHistory.pending = []
            tab.phpCheck = nil
            return
        }
        if let i = tab.phpHistory.pending.lastIndex(where: { $0.url == url }) {
            let check = PHPCheck(origin: origin, evidence: PHP2Shell.merge(.init(), tab.phpHistory.pending[i].evidence))
            tab.phpHistory.pending.removeFirst(i + 1)
            tab.phpCheck = check
            tab.phpHistory.remember(check)
        } else {
            // No response seen for it: the back/forward cache or a service worker.
            tab.phpCheck = tab.phpHistory.seen[origin]
        }
    }

    /// A password or card field got focus in a tab's main frame.
    func phpCheckSensitiveFocus(in webView: WKWebView, frameOrigin: String) {
        guard PHPCheck.enabled, let (_, _, tab) = owner(of: webView), !tab.phpWarned,
              let check = tab.phpCheck, check.verdict.level.warns, check.origin == frameOrigin,
              PHPCheck.origin(of: webView.url) == frameOrigin else { return }
        tab.phpWarned = true
        let lead = check.verdict.level == .vulnerable
            ? "Careful: this site reports an unpatched PHP version (PHP2Shell)."
            : "Heads up: this site's server may be unpatched (PHP2Shell)."
        ask(SitePrompt(key: "php2shell", symbol: "exclamationmark.triangle.fill",
                       message: "\(lead) Passwords and card numbers entered here could be stolen.",
                       allowTitle: "OK", denyTitle: nil) { _ in }, in: tab)
    }
}

/// Tells the app when a password or card field gets focus, in the top frame. It sends no field
/// values; the app decides whether the site warrants a warning.
final class SensitiveFieldReporter: NSObject, WKScriptMessageHandler {
    static let handlerName = "iSmithSensitiveField"
    static let source = """
    (() => {
      if (window !== top) return;
      const auto = /\\b(current-password|new-password|cc-number|cc-csc|cc-exp)/i;
      // Whole-word "pass"/"pwd" so passport, passenger and compass don't match.
      const named = /(^|[^a-z])(pass|pwd)($|[^a-z])|password|passwd|card.?num|cc.?num|cvv|cvc|security.?code/i;
      const sensitive = el => el instanceof HTMLInputElement && (el.type === 'password' ||
        auto.test(el.autocomplete || '') || named.test((el.name || '') + ' ' + (el.id || '')));
      let last = null;
      document.addEventListener('focusin', e => {
        // composedPath reaches inputs inside web components' shadow roots.
        const t = e.composedPath ? e.composedPath()[0] : e.target;
        if (t === last || !sensitive(t)) return;
        last = t;
        try { webkit.messageHandlers.\(handlerName).postMessage(1); } catch (_) {}
      }, true);
    })();
    """

    weak var browser: BrowserState?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let webView = message.webView else { return }
        let origin = PHPCheck.origin(of: message.frameInfo.securityOrigin)
        MainActor.assumeIsolated { browser?.phpCheckSensitiveFocus(in: webView, frameOrigin: origin) }
    }
}

// MARK: - Address bar

/// A warning triangle in the address bar when the page's server reports a PHP version vulnerable
/// to PHP2Shell (red) or one a Linux distribution may have patched (orange). Click for the details.
struct PHPCheckButton: View {
    @ObservedObject var tab: Tab
    @AppStorage(PHPCheck.enabledKey) private var enabled = true
    @State private var showing = false

    var body: some View {
        if enabled, let check = tab.phpCheck, check.verdict.level.warns, PHPCheck.origin(of: tab.url) == check.origin {
            let vulnerable = check.verdict.level == .vulnerable
            Button { showing.toggle() } label: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(vulnerable ? Color.red : Color.orange)
            }
            .buttonStyle(.borderless)
            .help(vulnerable ? "PHP2Shell: this server reports an unpatched PHP version"
                             : "PHP2Shell: unpatched version number, possibly patched by its Linux distribution")
            .accessibilityLabel(vulnerable ? "Unpatched PHP server" : "Possibly unpatched PHP server")
            .popover(isPresented: $showing, arrowEdge: .bottom) { PHPCheckDetails(check: check) }
            // A popover left open when the page moved on must not reopen on the next warned page.
            .onDisappear { showing = false }
        }
    }
}

struct PHPCheckDetails: View {
    let check: PHPCheck

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(check.verdict.level == .vulnerable ? "Unpatched PHP server" : "Possibly unpatched PHP server")
                .font(.headline)
            Text(check.verdict.reason).fixedSize(horizontal: false, vertical: true)
            Text("PHP2Shell (CVE-2026-109618, CVE-2026-109619) lets an attacker take over the server. Avoid entering passwords or card numbers here until the site is updated.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                Text("What the server reported").font(.caption).foregroundStyle(.secondary)
                ForEach(NSOrderedSet(array: check.evidence.signals + check.evidence.distroHints).array as? [String] ?? [], id: \.self) { line in
                    Text(line).font(.caption.monospaced()).textSelection(.enabled)
                }
            }
            Text("A hint, not proof: headers can be wrong, and a CDN can rewrite them. iSmith only reads what the site already sent.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("CISA alert", destination: PHP2Shell.advisoryURL).font(.caption)
        }
        .padding(14)
        .frame(width: 340)
    }
}
