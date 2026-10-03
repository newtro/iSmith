import AppKit
import Foundation
import UserNotifications
import WebKit

/// Web notifications for pages (Teams, Outlook, Gmail), delivered as macOS notifications.
///
/// WKWebView has the web `Notification` API, but `requestPermission()` always answers "denied"
/// (P0 finding), and there's no public delegate to change that. So iSmith replaces it:
///
/// - A page-world script defines `window.Notification` (and `ServiceWorkerRegistration`'s
///   `showNotification`, and `navigator.permissions.query` for "notifications") on top of a
///   private channel: DOM events whose name is random per app run.
/// - A script in iSmith's own content world (`WebNotifications.worldName`) listens for those
///   events and is the only thing that can reach the native message handler; the page world
///   never gets a handler. Each message carries the sending frame's security origin, which is
///   what permission is checked against, never anything the page says.
/// - Permission is per site (origin), global across spaces, stored in BrowserData's site
///   settings. Asking shows a bar on the tab; only a top-level page can ask (a cross-origin
///   iframe gets "denied").
/// - Notifications go to `UNUserNotificationCenter` through `WebNotificationPoster`; clicking one
///   focuses its tab and fires the page's `click` event.
@MainActor
final class WebNotifications: NSObject {
    static let worldName = "iSmith.app"
    static let handlerName = "ismithNotifications"

    /// The content world the bridge runs in (shared with iSmith's other non-password scripts).
    let world = WKContentWorld.world(name: WebNotifications.worldName)
    /// The private event names for this run.
    let channel = "ismith-n-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()

    /// Reads and saves per-site decisions.
    var decision: (_ origin: String) -> Bool?
    var saveDecision: (_ origin: String, _ allow: Bool) -> Void
    /// Asks the user (a bar on the tab showing `webView`). Unset: the request is denied.
    var ask: ((_ webView: WKWebView, _ host: String, _ origin: String, _ answer: @escaping (PromptAnswer) -> Void) -> Void)?
    /// The tab and space a web view belongs to, for the notification's subtitle and its click.
    var context: (_ webView: WKWebView) -> (tab: UUID, space: String)?
    var poster: WebNotificationPoster

    /// Notification id → where it came from, for clicks and `close()`.
    private var shown: [String: Shown] = [:]
    private struct Shown {
        weak var webView: WKWebView?
        let frame: WKFrameInfo
        let pageID: String
        let tab: UUID
    }

    init(poster: WebNotificationPoster,
         decision: @escaping (String) -> Bool?,
         saveDecision: @escaping (String, Bool) -> Void,
         context: @escaping (WKWebView) -> (tab: UUID, space: String)?) {
        self.poster = poster
        self.decision = decision
        self.saveDecision = saveDecision
        self.context = context
        super.init()
    }

    // MARK: - Installing

    /// Adds the scripts and the handler to a configuration's content controller (once).
    func install(in controller: WKUserContentController) {
        guard !controller.userScripts.contains(where: { $0.source.contains(channel) }) else { return }
        // The bridge first, so it's listening before the page shim sends its first message.
        controller.addUserScript(WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: world))
        controller.addUserScript(WKUserScript(source: pageScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: .page))
        controller.addScriptMessageHandler(ReplyProxy(self), contentWorld: world, name: Self.handlerName)
    }

    /// Tells open pages of a site that its permission changed (from Settings).
    func permissionChanged(origin: String, in webViews: [WKWebView]) {
        let state = permission(for: origin)
        for webView in webViews {
            send(["type": "permission", "origin": origin, "permission": state], to: webView, frame: nil)
        }
    }

    private func permission(for origin: String) -> String {
        switch decision(origin) {
        case true?: return "granted"
        case false?: return "denied"
        case nil: return "default"
        }
    }

    // MARK: - Messages from pages

    fileprivate func receive(_ message: WKScriptMessage) async -> Any? {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let webView = message.webView else { return nil }
        let frame = message.frameInfo
        let origin = frame.securityOrigin.originKey
        switch type {
        case "query":
            return ["type": "permission", "permission": permission(for: origin)]
        case "request":
            let id = body["id"] as? Int ?? 0
            let result = await request(origin: origin, host: frame.securityOrigin.displayHost, frame: frame, webView: webView)
            return ["type": "requestResult", "id": id, "permission": result]
        case "show":
            guard decision(origin) == true, let ctx = context(webView) else {
                return ["type": "error", "id": body["id"] as? String ?? ""]
            }
            let pageID = body["id"] as? String ?? UUID().uuidString
            let tag = (body["tag"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            // A tag replaces the site's earlier notification with the same tag, as on the web.
            let id = tag.map { "\(origin)#tag:\($0)" } ?? "\(origin)#\(UUID().uuidString)"
            let note = WebNotification(id: id, title: Self.clip(body["title"] as? String ?? "", 200),
                                       body: Self.clip(body["body"] as? String ?? "", 1000),
                                       site: frame.securityOrigin.displayHost, space: ctx.space,
                                       tab: ctx.tab, silent: body["silent"] as? Bool ?? false)
            if let old = shown[id], old.pageID != pageID { send(["type": "close", "id": old.pageID], to: old.webView, frame: old.frame) }
            shown[id] = Shown(webView: webView, frame: frame, pageID: pageID, tab: ctx.tab)
            poster.post(note)
            return ["type": "show", "id": pageID]
        case "close":
            let pageID = body["id"] as? String ?? ""
            for (id, s) in shown where s.pageID == pageID && s.webView === webView {
                shown[id] = nil
                poster.remove(ids: [id])
            }
            return nil
        default:
            return nil
        }
    }

    private func request(origin: String, host: String, frame: WKFrameInfo, webView: WKWebView) async -> String {
        if let saved = decision(origin) { return saved ? "granted" : "denied" }
        // Only the page itself can ask, not an iframe from another site.
        guard frame.isMainFrame || webView.url.flatMap(Self.originKey) == origin, let ask else { return "default" }
        let answer: PromptAnswer = await withCheckedContinuation { continuation in
            ask(webView, host, origin) { continuation.resume(returning: $0) }
        }
        switch answer {
        case .allow:
            saveDecision(origin, true)
            poster.requestAuthorization()
            return "granted"
        case .deny:
            saveDecision(origin, false)
            return "denied"
        case .dismissed:
            return "default"
        }
    }

    // MARK: - Clicks

    /// The user clicked a notification: the page gets its `click` event. Returns the tab to show.
    @discardableResult
    func clicked(_ id: String) -> UUID? {
        guard let s = shown[id] else { return nil }
        send(["type": "click", "id": s.pageID], to: s.webView, frame: s.frame)
        return s.tab
    }

    /// The notification was dismissed in Notification Center.
    func dismissed(_ id: String) {
        guard let s = shown.removeValue(forKey: id) else { return }
        send(["type": "close", "id": s.pageID], to: s.webView, frame: s.frame)
    }

    /// A tab closed: its notifications stay in Notification Center but no longer reach a page.
    func forget(_ webView: WKWebView) {
        shown = shown.filter { $0.value.webView != nil && $0.value.webView !== webView }
    }

    private func send(_ message: [String: Any], to webView: WKWebView?, frame: WKFrameInfo?) {
        guard let webView, let data = try? JSONSerialization.data(withJSONObject: message),
              let json = String(data: data, encoding: .utf8) else { return }
        let js = "document.dispatchEvent(new CustomEvent(\(Self.literal(channel + "-in")), {detail: \(Self.literal(json))}))"
        webView.evaluateJavaScript(js, in: frame, in: world, completionHandler: nil)
    }

    // MARK: - Scripts

    private static func literal(_ s: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
        return String(String(data: data, encoding: .utf8)!.dropFirst().dropLast())
    }

    private static func clip(_ s: String, _ n: Int) -> String {
        s.count > n ? String(s.prefix(n)) + "…" : s
    }

    static func originKey(_ url: URL) -> String? {
        guard let scheme = url.scheme, let host = url.host else { return nil }
        return WKSecurityOrigin.key(scheme: scheme, host: host, port: url.port ?? 0)
    }

    /// Runs in iSmith's world: passes the page shim's requests to the app and the answers back.
    private var bridgeScript: String {
        """
        (() => {
          const ev = \(Self.literal(channel));
          document.addEventListener(ev + "-out", async (e) => {
            if (typeof e.detail !== "string" || e.detail.length > 20000) return;
            let msg;
            try { msg = JSON.parse(e.detail); } catch (_) { return; }
            if (!msg || typeof msg.type !== "string") return;
            let reply = null;
            try { reply = await window.webkit.messageHandlers.\(Self.handlerName).postMessage(msg); } catch (_) {}
            // A request always settles, even if the app couldn't answer.
            if (!reply && msg.type === "request") reply = { type: "requestResult", id: msg.id, permission: "default" };
            if (reply) document.dispatchEvent(new CustomEvent(ev + "-in", { detail: JSON.stringify(reply) }));
          }, true);
        })();
        """
    }

    /// Runs in the page's world: the web `Notification` API, backed by the bridge.
    private var pageScript: String {
        """
        (() => {
          const ev = \(Self.literal(channel));
          let permission = "default";
          const pending = new Map();
          const live = new Map();
          let seq = 0;
          const send = (msg) => document.dispatchEvent(new CustomEvent(ev + "-out", { detail: JSON.stringify(msg) }));
          const fire = (n, type) => {
            const e = new Event(type, { cancelable: type === "click" });
            const h = n["on" + type];
            try { if (typeof h === "function") h.call(n, e); } catch (err) { setTimeout(() => { throw err; }); }
            n.dispatchEvent(e);
            if (type === "close" || type === "error") live.delete(idOf.get(n));
          };
          const idOf = new WeakMap();
          document.addEventListener(ev + "-in", (e) => {
            if (typeof e.detail !== "string") return;
            let msg;
            try { msg = JSON.parse(e.detail); } catch (_) { return; }
            if (msg.type === "permission") {
              if (!msg.origin || msg.origin === location.origin) permission = msg.permission;
            } else if (msg.type === "requestResult") {
              permission = msg.permission;
              const done = pending.get(msg.id);
              if (done) { pending.delete(msg.id); done(msg.permission); }
            } else if (msg.type === "show" || msg.type === "click" || msg.type === "close" || msg.type === "error") {
              const n = live.get(msg.id);
              if (n) fire(n, msg.type);
            }
          }, true);
          class Notification extends EventTarget {
            constructor(title, options) {
              super();
              if (arguments.length < 1) throw new TypeError("Failed to construct 'Notification': 1 argument required, but only 0 present.");
              const o = options || {};
              const id = "n" + (++seq) + "-" + Math.random().toString(36).slice(2);
              idOf.set(this, id);
              Object.defineProperties(this, {
                title: { value: String(title), enumerable: true },
                body: { value: o.body === undefined ? "" : String(o.body), enumerable: true },
                tag: { value: o.tag === undefined ? "" : String(o.tag), enumerable: true },
                icon: { value: o.icon === undefined ? "" : String(o.icon), enumerable: true },
                data: { value: o.data === undefined ? null : o.data, enumerable: true },
                silent: { value: !!o.silent, enumerable: true },
                requireInteraction: { value: !!o.requireInteraction, enumerable: true },
                dir: { value: o.dir || "auto", enumerable: true },
                lang: { value: o.lang || "", enumerable: true },
              });
              this.onclick = null; this.onshow = null; this.onclose = null; this.onerror = null;
              live.set(id, this);
              // The app decides; the page's copy of the permission may not have arrived yet.
              setTimeout(() => {
                if (permission === "denied") { fire(this, "error"); return; }
                send({ type: "show", id, title: this.title, body: this.body, tag: this.tag, silent: this.silent });
              }, 0);
            }
            close() { const id = idOf.get(this); send({ type: "close", id }); setTimeout(() => { if (live.has(id)) fire(this, "close"); }, 0); }
            static get permission() { return permission; }
            static get maxActions() { return 0; }
            static requestPermission(callback) {
              return new Promise((resolve) => {
                const done = (p) => { try { if (typeof callback === "function") callback(p); } finally { resolve(p); } };
                if (permission !== "default") { done(permission); return; }
                const id = ++seq;
                pending.set(id, done);
                send({ type: "request", id });
              });
            }
          }
          const define = (obj, name, value) => { try { Object.defineProperty(obj, name, { value, writable: true, configurable: true }); } catch (_) {} };
          define(window, "Notification", Notification);
          if (window.ServiceWorkerRegistration) {
            define(ServiceWorkerRegistration.prototype, "showNotification", function (title, options) {
              if (permission !== "granted") return Promise.reject(new TypeError("No notification permission has been granted for this origin."));
              new Notification(title, options);
              return Promise.resolve();
            });
            define(ServiceWorkerRegistration.prototype, "getNotifications", function () { return Promise.resolve([]); });
          }
          if (navigator.permissions && navigator.permissions.query) {
            const query = navigator.permissions.query.bind(navigator.permissions);
            define(navigator.permissions, "query", function (desc) {
              if (desc && desc.name === "notifications") {
                const state = permission === "default" ? "prompt" : permission;
                return Promise.resolve(Object.assign(new EventTarget(), { state, name: "notifications", onchange: null }));
              }
              return query(desc);
            });
          }
          send({ type: "query" });
          // In case the bridge wasn't listening yet at document start.
          document.addEventListener("DOMContentLoaded", () => { if (permission === "default") send({ type: "query" }); }, { once: true });
        })();
        """
    }
}

/// The handler WebKit holds; it only keeps the notifications object weakly, so no cycle.
private final class ReplyProxy: NSObject, WKScriptMessageHandlerWithReply {
    weak var target: WebNotifications?

    init(_ target: WebNotifications) {
        self.target = target
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping (Any?, String?) -> Void) {
        MainActor.assumeIsolated {
            guard let target else { return replyHandler(nil, nil) }
            Task { @MainActor in
                replyHandler(await target.receive(message), nil)
            }
        }
    }
}

/// One web notification as macOS shows it.
struct WebNotification: Equatable {
    /// The identifier in Notification Center: the site plus its tag, so a tag replaces.
    let id: String
    let title: String
    let body: String
    /// "teams.microsoft.com"
    let site: String
    /// The space's name, shown with the site.
    let space: String
    let tab: UUID
    let silent: Bool
}

/// Where notifications go: `UNUserNotificationCenter` in the app, a recorder in tests.
@MainActor
protocol WebNotificationPoster: AnyObject {
    func post(_ notification: WebNotification)
    func remove(ids: [String])
    /// Asks macOS for permission to show notifications (once; macOS remembers the answer).
    func requestAuthorization()
}

/// Delivers web notifications through Notification Center. Clicking one calls `onClick` with
/// the notification's id; the app focuses the tab.
@MainActor
final class SystemNotificationPoster: NSObject, WebNotificationPoster, UNUserNotificationCenterDelegate {
    var onClick: ((String) -> Void)?
    var onDismiss: ((String) -> Void)?
    private let center = UNUserNotificationCenter.current()
    private var authorized: Bool?

    override init() {
        super.init()
        center.delegate = self
        center.getNotificationSettings { settings in
            let status = settings.authorizationStatus
            Task { @MainActor in self.authorized = status == .authorized || status == .provisional }
        }
    }

    func requestAuthorization() {
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            Task { @MainActor in self.authorized = granted }
        }
    }

    func post(_ notification: WebNotification) {
        if authorized != true { requestAuthorization() }
        let content = UNMutableNotificationContent()
        content.title = notification.title.isEmpty ? notification.site : notification.title
        content.subtitle = "\(notification.site) · \(notification.space)"
        content.body = notification.body
        content.sound = notification.silent ? nil : .default
        content.threadIdentifier = notification.site
        content.userInfo = ["tab": notification.tab.uuidString]
        center.add(UNNotificationRequest(identifier: notification.id, content: content, trigger: nil))
    }

    func remove(ids: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: ids)
        center.removePendingNotificationRequests(withIdentifiers: ids)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.identifier
        let action = response.actionIdentifier
        Task { @MainActor in
            if action == UNNotificationDismissActionIdentifier { self.onDismiss?(id) } else { self.onClick?(id) }
            completionHandler()
        }
    }
}
