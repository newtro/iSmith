import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

/// Site icons for tabs (pinned tabs show only this), kept in memory per origin. They're fetched
/// only for a page that has just loaded in a tab, so a restored tab that hasn't loaded asks no
/// site for anything (it shows a letter until it loads). The icon is the one the page names
/// (`<link rel="icon">`) when it's on the page's own site, otherwise the origin's `/favicon.ico`.
///
/// Fetches carry no cookies (an ephemeral session, so no space's session goes with them), stop
/// at `maxBytes` and `timeout`, and are decoded by ImageIO as a small thumbnail of a raster type
/// only (PNG, ICO, JPEG, GIF, WebP, BMP): never SVG or PDF, and never an image larger than
/// `maxPixels`, so a hostile icon can't use much memory or reach a complex decoder.
@MainActor
final class Favicons: ObservableObject {
    static let shared = Favicons()

    /// Bumped whenever an icon arrives; views showing icons redraw.
    @Published private(set) var generation = 0
    private var images: [String: NSImage] = [:]
    /// The address each origin's icon came from, so a page that loads again doesn't fetch it again.
    private var sources: [String: URL] = [:]
    private var loading: Set<String> = []
    /// Origins whose icon couldn't be had, and when: not asked again for a while.
    private var failed: [String: Date] = [:]
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = Favicons.timeout
        return URLSession(configuration: configuration)
    }()

    static let maxBytes = 256 * 1024
    static let maxPixels = 1024 * 1024
    static let timeout: TimeInterval = 15
    static let allowedTypes: Set<String> = [UTType.png, .ico, .jpeg, .gif, .webP, .bmp].map(\.identifier).reduce(into: []) { $0.insert($1) }

    /// Icons are kept per origin (scheme, host and port).
    static func key(_ url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host?.lowercased() else { return nil }
        return "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "")
    }

    /// The icon for a page, if one has been fetched.
    func icon(for url: URL?) -> NSImage? {
        Self.key(url).flatMap { images[$0] }
    }

    /// Whether a page's named icon may be fetched: on the page's own host or a host sharing its
    /// last two labels (`static.contoso.com` for `mail.contoso.com`). Anything else, such as a
    /// tracker's address, falls back to the page's `/favicon.ico`.
    static func sameSite(_ icon: URL, as page: URL) -> Bool {
        guard ["http", "https"].contains(icon.scheme?.lowercased() ?? ""),
              let a = icon.host?.lowercased(), let b = page.host?.lowercased() else { return false }
        func site(_ host: String) -> String { host.split(separator: ".").suffix(2).joined(separator: ".") }
        return a == b || site(a) == site(b)
    }

    /// A page finished loading: its icon is fetched, unless it's already here.
    func pageLoaded(_ webView: WKWebView) {
        guard let page = webView.url, let key = Self.key(page) else { return }
        let script = """
            const links = [...document.querySelectorAll('link[rel~="icon" i], link[rel="shortcut icon" i], link[rel="apple-touch-icon" i]')]
              .filter(l => l.href && !/svg/i.test(l.type || '') && !/\\.svg(\\?|#|$)/i.test(l.href));
            const size = l => Math.max(0, ...((l.getAttribute('sizes') || '').split(/\\s+/).map(s => parseInt(s, 10) || 0)));
            const touch = l => /apple-touch-icon/i.test(l.rel) ? 1 : 0;
            links.sort((a, b) => touch(a) - touch(b) || Math.abs(size(a) - 32) - Math.abs(size(b) - 32));
            return links.length ? links[0].href : null;
            """
        webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .defaultClient) { [weak self] result in
            guard let self else { return }
            var source = URL(string: "/favicon.ico", relativeTo: page)?.absoluteURL
            if case let .success(value) = result, let href = value as? String, let named = URL(string: href),
               Self.sameSite(named, as: page) {
                source = named
            }
            if let source { self.fetch(source, for: key) }
        }
    }

    private func fetch(_ url: URL, for key: String) {
        guard !loading.contains(key), sources[key] != url || images[key] == nil else { return }
        if images[key] == nil, let at = failed[key], Date().timeIntervalSince(at) < 15 * 60 { return }
        loading.insert(key)
        let session = session
        Task { [weak self] in
            let image = await Self.download(url, session: session).flatMap(Self.decode)
            guard let self else { return }
            self.loading.remove(key)
            if let image {
                self.images[key] = image
                self.sources[key] = url
                self.failed[key] = nil
                self.generation += 1
            } else if self.images[key] == nil {
                self.failed[key] = Date()
            }
        }
    }

    /// The response body, or nil past `maxBytes` (stopping there) or on an error status.
    nonisolated static func download(_ url: URL, session: URLSession) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url) else { return nil }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return nil }
        if response.expectedContentLength > Int64(maxBytes) { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maxBytes { return nil }
            }
        } catch {
            return nil
        }
        return data
    }

    /// A small image from icon bytes: raster types only, no larger than `maxPixels`, scaled down
    /// to at most 64 pixels.
    nonisolated static func decode(_ data: Data) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, allowedTypes.contains(type),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxPixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 64,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: image, size: NSSize(width: 16, height: 16))
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
