import AppKit
import WebKit

/// What Teams and Meet calls need from WKWebView: media devices, screen sharing, notifications.
/// Run with `--selftest --phase=feasibility`. Media permission requests are denied so the camera
/// never opens; the point is whether the APIs exist and reach the app.
@MainActor
final class FeasibilityProbe: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var window: NSWindow!
    private var prompts: [String] = []
    private var done: CheckedContinuation<Void, Never>?

    func run() async {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.preferences.inactiveSchedulingPolicy = .none
        config.preferences.isElementFullscreenEnabled = true
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.customUserAgent = BrowserState.userAgent
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView!.addSubview(webView)
        window.orderFront(nil)
        webView.load(URLRequest(url: URL(string: "https://webrtc.github.io/samples/")!))
        await withCheckedContinuation { done = $0 }
        exit(0)
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        prompts.append(["camera", "microphone", "camera+microphone"][min(type.rawValue, 2)])
        decisionHandler(.deny)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let js = """
            const md = navigator.mediaDevices;
            async function tryCall(fn) { try { const s = await fn(); s.getTracks().forEach(t => t.stop()); return 'ok'; } catch (e) { return e.name + ': ' + e.message; } }
            const r = {
              mediaDevices: !!md,
              getUserMedia: !!(md && md.getUserMedia),
              getDisplayMedia: !!(md && md.getDisplayMedia),
              Notification: typeof Notification,
              PushManager: typeof PushManager,
            };
            r.getUserMediaResult = r.getUserMedia ? await tryCall(() => md.getUserMedia({audio: true})) : 'missing';
            r.getDisplayMediaResult = r.getDisplayMedia ? await tryCall(() => md.getDisplayMedia({video: true})) : 'missing';
            if (typeof Notification === 'function') {
              try { r.notificationRequest = await Notification.requestPermission(); } catch (e) { r.notificationRequest = e.name + ': ' + e.message; }
            }
            return JSON.stringify(r, null, 2);
            """
            do { print(try await webView.callAsyncJavaScript(js, contentWorld: .page) ?? "nil") } catch { print("JS error: \(error)") }
            print("Media permission requests that reached the app: \(prompts)")
            done?.resume()
        }
    }
}
