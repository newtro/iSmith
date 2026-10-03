// Probes WKWebView for what Teams and Meet calls need: media devices, screen sharing,
// notifications and background scheduling. Run: swift spike/feasibility/probe.swift
import AppKit
import WebKit

final class Probe: NSObject, WKNavigationDelegate, WKUIDelegate {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    var webView: WKWebView!
    var mediaPrompts: [String] = []

    func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        if #available(macOS 14.0, *) { config.preferences.inactiveSchedulingPolicy = .none }
        config.preferences.isElementFullscreenEnabled = true
        webView = WKWebView(frame: window.contentView!.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        window.contentView!.addSubview(webView)
        window.orderFront(nil)
        webView.load(URLRequest(url: URL(string: "https://webrtc.github.io/samples/")!))
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        mediaPrompts.append("\(type.rawValue)")
        decisionHandler(.deny) // probe only: don't open the camera
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let js = """
            const md = navigator.mediaDevices;
            const r = {
              secureContext: window.isSecureContext,
              mediaDevices: !!md,
              getUserMedia: !!(md && md.getUserMedia),
              getDisplayMedia: !!(md && md.getDisplayMedia),
              Notification: typeof Notification,
              notificationPermission: typeof Notification === 'undefined' ? null : Notification.permission,
              PushManager: typeof PushManager,
              serviceWorker: 'serviceWorker' in navigator,
              RTCPeerConnection: typeof RTCPeerConnection,
              userAgent: navigator.userAgent
            };
            async function tryCall(fn) { try { const s = await fn(); s.getTracks().forEach(t => t.stop()); return 'ok'; } catch (e) { return e.name + ': ' + e.message; } }
            r.getUserMediaResult = md && md.getUserMedia ? await tryCall(() => md.getUserMedia({audio: true})) : 'missing';
            r.getDisplayMediaResult = md && md.getDisplayMedia ? await tryCall(() => md.getDisplayMedia({video: true})) : 'missing';
            return JSON.stringify(r, null, 2);
            """
            do {
                let result = try await webView.callAsyncJavaScript(js, contentWorld: .page)
                print(result ?? "nil")
            } catch { print("JS error: \(error)") }
            print("mediaCapture permission requests seen by the app: \(self.mediaPrompts)")
            print("macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe()
probe.start()
DispatchQueue.main.asyncAfter(deadline: .now() + 60) { print("timeout"); exit(1) }
app.run()
