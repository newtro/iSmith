import AppKit
import Foundation
import Security
import SecurityInterface
import WebKit

/// How a site prompt was answered. `dismissed` (the tab closed or navigated away) is never
/// remembered.
enum PromptAnswer {
    case allow, deny, dismissed
}

/// A question from a page, shown as a bar over the page rather than a modal dialog, so a page in
/// a background tab can't take over the window: camera, microphone and location, notifications,
/// and opening another app. Answering removes it from its tab.
@MainActor
final class SitePrompt: Identifiable {
    let id = UUID()
    /// What it's about, for the bar's icon (an SF Symbol).
    let symbol: String
    let message: String
    let allowTitle: String
    let denyTitle: String?
    /// Prompts with the same key in one tab are asked once; later requests wait for that answer.
    let key: String
    private var handlers: [(PromptAnswer) -> Void]

    init(key: String, symbol: String, message: String, allowTitle: String, denyTitle: String? = "Don't Allow",
         handler: @escaping (PromptAnswer) -> Void) {
        self.key = key
        self.symbol = symbol
        self.message = message
        self.allowTitle = allowTitle
        self.denyTitle = denyTitle
        handlers = [handler]
    }

    func join(_ handler: @escaping (PromptAnswer) -> Void) {
        handlers.append(handler)
    }

    /// Calls every waiting handler once.
    func answer(_ answer: PromptAnswer) {
        let waiting = handlers
        handlers = []
        for handler in waiting { handler(answer) }
    }
}

/// A modal question the page is waiting on (JavaScript alert, confirm, prompt; HTTP sign-in;
/// a file picker). It's shown as a sheet on the tab's window once the tab is on screen; until then
/// it waits in the tab. `cancel` answers it without the user (the tab closed).
@MainActor
struct PendingDialog {
    /// Shows the sheet and calls `done` when it's gone.
    let show: (_ window: NSWindow, _ done: @escaping () -> Void) -> Void
    let cancel: () -> Void
}

/// A navigation stopped by a certificate problem, or a page that couldn't be reached. The tab
/// shows a warning page with the choices.
struct CertificateProblem: Identifiable {
    let id = UUID()
    let url: URL
    let message: String
    /// The server's certificate chain, when the problem is the certificate.
    let trust: SecTrust?
    var isCertificate: Bool { trust != nil }
}

/// Certificate exceptions the user accepted ("Visit This Website" on the warning page), for this
/// run of the app only: host → the leaf certificate they saw. A different certificate on the same
/// host is checked normally again.
@MainActor
final class CertificateExceptions {
    private var accepted: [String: Data] = [:]

    func accept(host: String, trust: SecTrust) {
        guard let leaf = Self.leaf(trust) else { return }
        accepted[host.lowercased()] = leaf
    }

    func allows(host: String, trust: SecTrust) -> Bool {
        guard let saved = accepted[host.lowercased()], let leaf = Self.leaf(trust) else { return false }
        return saved == leaf
    }

    static func leaf(_ trust: SecTrust) -> Data? {
        guard let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate], let first = chain.first else { return nil }
        return SecCertificateCopyData(first) as Data
    }
}

/// The site a frame belongs to, as the prompts name it ("teams.microsoft.com").
extension WKSecurityOrigin {
    var displayHost: String {
        host.isEmpty ? self.protocol : host
    }

    /// A sandboxed or data: frame: it has no site to grant anything to.
    var isOpaque: Bool { self.protocol.isEmpty || (host.isEmpty && ["http", "https"].contains(self.protocol.lowercased())) }

    /// "https://teams.microsoft.com", default ports left out: the key site settings use.
    var originKey: String {
        Self.key(scheme: self.protocol, host: host, port: port)
    }

    static func key(scheme: String, host: String, port: Int) -> String {
        let scheme = scheme.lowercased()
        let host = host.lowercased()
        let defaultPort = (scheme == "https" && port == 443) || (scheme == "http" && port == 80) || port == 0
        return defaultPort ? "\(scheme)://\(host)" : "\(scheme)://\(host):\(port)"
    }
}
