import AppKit
import WebKit

/// A plain-text log of what tabs and their web views do (navigations, popups, selection, which
/// view is on screen), for tracking down pages that show blank. Pages are named by host and
/// path only, never their query or contents. ~/Library/Logs/iSmith/diagnostics.log (iSmith Dev:
/// "iSmith Dev"), started afresh once it passes 2 MB.
@MainActor
enum Diagnostics {
    static let fileURL: URL = {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "iSmith"
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/\(name)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("diagnostics.log")
    }()

    private static let maxSize = 2_000_000
    private static var handle: FileHandle? = {
        let path = fileURL.path
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
        if size > maxSize || !FileManager.default.fileExists(atPath: path) {
            FileManager.default.createFile(atPath: path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: fileURL)
        handle?.seekToEndOfFile()
        return handle
    }()

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static func log(_ message: String) {
        guard let handle, let data = "\(stamp.string(from: Date())) \(message)\n".data(using: .utf8) else { return }
        handle.write(data)
    }

    /// Host and path, without the query or fragment.
    static func page(_ url: URL?) -> String {
        guard let url else { return "-" }
        guard let host = url.host else { return url.scheme ?? "?" }
        return host + url.path
    }

    static func id(_ tab: Tab) -> String { String(tab.id.uuidString.prefix(8)) }

    static func id(_ webView: WKWebView?) -> String {
        guard let webView else { return "none" }
        return String(UInt(bitPattern: ObjectIdentifier(webView).hashValue) & 0xFFFFFF, radix: 16)
    }

    /// Where a web view is: its window, the view holding it, and whether it can be seen.
    static func placement(_ webView: WKWebView?) -> String {
        guard let webView else { return "wv=none" }
        let holder = webView.superview.map { String(describing: type(of: $0)) } ?? "nil"
        let window = webView.window.map { $0.isVisible ? ($0 is NSPanel ? "panel" : "window") : "hidden-window" } ?? "nil"
        let f = webView.frame
        return "wv=\(id(webView)) in=\(holder) win=\(window) hidden=\(webView.isHiddenOrHasHiddenAncestor) alpha=\(webView.alphaValue) frame=\(Int(f.width))x\(Int(f.height)) loading=\(webView.isLoading)"
    }

    /// What the page holds and what is drawn: the DOM's title and size, and whether a snapshot of
    /// the view is one flat color (nothing drawn).
    static func check(_ webView: WKWebView, label: String) {
        let script = "[document.title, document.body ? document.body.innerHTML.length : -1, document.visibilityState].join('|')"
        webView.evaluateJavaScript(script, in: nil, in: .defaultClient) { result in
            let dom: String
            switch result {
            case .success(let value): dom = "\(value)"
            case .failure(let error): dom = "error \(error.localizedDescription)"
            }
            webView.takeSnapshot(with: nil) { image, error in
                let drawn = image.map(colors) ?? "snapshot failed \(error?.localizedDescription ?? "")"
                log("check \(label) wv=\(id(webView)) \(page(webView.url)) dom=\(dom) drawn=\(drawn) \(placement(webView))")
            }
        }
    }

    /// How many distinct colors a 12×12 grid of the image has: 1 means a flat page.
    private static func colors(_ image: NSImage) -> String {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return "no image" }
        let width = 12, height = 12
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return "no context" }
        context.interpolationQuality = .none
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        var seen = Set<UInt32>()
        for i in stride(from: 0, to: pixels.count, by: 4) {
            seen.insert(UInt32(pixels[i]) << 16 | UInt32(pixels[i + 1]) << 8 | UInt32(pixels[i + 2]))
        }
        let first = String(format: "%06x", seen.first ?? 0)
        return "\(seen.count) colors (\(cg.width)x\(cg.height), e.g. #\(first))"
    }
}
