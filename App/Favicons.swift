import AppKit
import WebKit

/// Site icons for tabs (pinned tabs show only this), kept in memory per origin. A loaded page says
/// which icon it uses (`<link rel="icon">`); a tab that hasn't loaded yet (restored at launch)
/// asks for the site's `/favicon.ico`. Icons are fetched without cookies, so no space's session
/// goes with them. A site without one gets a letter.
@MainActor
final class Favicons: ObservableObject {
    static let shared = Favicons()

    /// Bumped whenever an icon arrives; views showing icons redraw.
    @Published private(set) var generation = 0
    private var images: [String: NSImage] = [:]
    private var loading: Set<String> = []
    /// Origins whose icon couldn't be had, and when: not asked again for a while.
    private var failed: [String: Date] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    static let maxBytes = 512 * 1024

    /// Icons are kept per origin (scheme, host and port).
    static func key(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// The icon for a page, if there is one yet. Asks for the site's default icon the first time.
    func icon(for url: URL?) -> NSImage? {
        guard let key = Self.key(url), let url else { return nil }
        if let image = images[key] { return image }
        var parts = URLComponents()
        parts.scheme = url.scheme
        parts.host = url.host
        parts.port = url.port
        parts.path = "/favicon.ico"
        if let fallback = parts.url { fetch(fallback, for: key) }
        return nil
    }

    /// A page finished loading: the icon it names replaces the default one.
    func pageLoaded(_ webView: WKWebView) {
        guard let key = Self.key(webView.url) else { return }
        let script = """
            const links = [...document.querySelectorAll('link[rel~="icon" i], link[rel="shortcut icon" i], link[rel="apple-touch-icon" i]')];
            const size = l => Math.max(0, ...((l.getAttribute('sizes') || '').split(/\\s+/).map(s => parseInt(s, 10) || 0)));
            const pick = links.filter(l => l.href).sort((a, b) => {
              const touch = l => /apple-touch-icon/i.test(l.rel) ? 1 : 0;
              return touch(a) - touch(b) || Math.abs(size(a) - 32) - Math.abs(size(b) - 32);
            })[0];
            return pick ? pick.href : null;
            """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self, case let .success(value) = result, let href = value as? String, let url = URL(string: href),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            self.fetch(url, for: key, replacing: true)
        }
    }

    private func fetch(_ url: URL, for key: String, replacing: Bool = false) {
        guard !loading.contains(key), replacing || images[key] == nil else { return }
        if !replacing, let at = failed[key], Date().timeIntervalSince(at) < 15 * 60 { return }
        loading.insert(key)
        let session = session
        Task { [weak self] in
            var image: NSImage?
            if let (data, response) = try? await session.data(from: url),
               (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
               data.count <= Self.maxBytes, let decoded = NSImage(data: data), decoded.isValid {
                image = decoded
            }
            guard let self else { return }
            self.loading.remove(key)
            if let image {
                self.images[key] = image
                self.failed[key] = nil
                self.generation += 1
            } else if self.images[key] == nil {
                self.failed[key] = Date()
            }
        }
    }

    /// A letter on a grey tile for a site without an icon (or an empty tab).
    static func placeholder(for url: URL?, title: String) -> NSImage {
        var host = url?.host ?? ""
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let letter = (host.first ?? title.first).map { String($0).uppercased() } ?? "•"
        return NSImage(size: NSSize(width: 16, height: 16), flipped: false) { rect in
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 10, weight: .bold),
                .foregroundColor: NSColor.white,
            ]
            let size = letter.size(withAttributes: attributes)
            letter.draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
            return true
        }
    }

    /// What a tab shows: its site's icon, or the placeholder.
    func image(for tab: Tab) -> NSImage {
        icon(for: tab.url) ?? Self.placeholder(for: tab.url, title: tab.title)
    }
}
