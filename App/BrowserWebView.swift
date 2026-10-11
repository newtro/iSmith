import AppKit
import WebKit

/// iSmith's web view: WebKit's own context menu, with "Open Link in New Tab", "Open Link in
/// Space ▸", "Download Linked File" and "Save Image As…" in place of WebKit's new-window and
/// download items (which a third-party app can't route to a tab or a download it tracks).
///
/// WebKit doesn't tell the app which link or image a menu is for. A small script in iSmith's
/// content world reports the element under the pointer on `contextmenu`; WebKit sends that
/// message before it asks the app to show the menu, so `willOpenMenu` reads it.
final class BrowserWebView: WKWebView {
    /// The user's last click or key press in the page (app links honor a remembered "Open" only
    /// right after one).
    private(set) var lastUserInput: Date?
    /// Set while the agent's tools deliver events: those aren't the user's input.
    var deliveringAgentInput = false
    /// The user edited something in the page since it last loaded (typed, pasted, dropped,
    /// dictated), so it isn't hibernated: the text may be unsaved.
    var editedSinceLoad = false

    override func mouseDown(with event: NSEvent) {
        if !deliveringAgentInput { lastUserInput = Date() }
        if event.modifierFlags.contains(.control) { contextElement = nil }
        super.mouseDown(with: event)
    }

    /// A report left by an earlier right-click (one the page answered with its own menu) isn't
    /// about this one: the page reports the new element after the mouse goes down.
    override func rightMouseDown(with event: NSEvent) {
        contextElement = nil
        super.rightMouseDown(with: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        if !deliveringAgentInput { lastUserInput = Date() }
        super.otherMouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        if !deliveringAgentInput { lastUserInput = Date() }
        super.keyDown(with: event)
    }

    /// Called when the web view joins or leaves a window (a tab switch takes it out of its
    /// window): the autofill popover anchored to it closes.
    var windowChanged: ((BrowserWebView) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        windowChanged?(self)
    }
    /// The element the last context menu was opened on.
    var contextElement: ContextElement?
    /// Builds the app's items for a link or image; set by `BrowserState`.
    var contextItems: ((BrowserWebView, ContextElement) -> ContextMenuItems)?
    /// Builds the open-link items when the page couldn't report the link (a frame sandboxed
    /// without scripts, as webmail shows messages): the closure is given the space picked (nil:
    /// a tab here) and runs WebKit's own item, whose new web view `BrowserState` reroutes.
    var fallbackLinkItems: ((BrowserWebView, @escaping (String?) -> Void) -> [NSMenuItem])?
    /// Where the next new web view WebKit asks for goes, set by a fallback item just before it
    /// runs WebKit's "Open Link in New Window".
    private var pendingLinkTarget: (space: String?, time: Date)?

    /// The pending fallback target, once, if it was set within the last few seconds.
    func takePendingLinkTarget() -> String?? {
        defer { pendingLinkTarget = nil }
        guard let pending = pendingLinkTarget, Date().timeIntervalSince(pending.time) < 5 else { return nil }
        return .some(pending.space)
    }

    struct ContextElement {
        var link: URL?
        var image: URL?
        var time = Date()
    }

    /// The app's replacements, by the WebKit item they replace.
    struct ContextMenuItems {
        var openLink: [NSMenuItem] = []
        var downloadLink: NSMenuItem?
        var openImage: NSMenuItem?
        var saveImage: NSMenuItem?
    }

    /// WebKit's menu item identifiers (stable strings, not in the public headers).
    enum Identifier {
        static let openLinkInNewWindow = "WKMenuItemIdentifierOpenLinkInNewWindow"
        static let downloadLinkedFile = "WKMenuItemIdentifierDownloadLinkedFile"
        static let openImageInNewWindow = "WKMenuItemIdentifierOpenImageInNewWindow"
        static let downloadImage = "WKMenuItemIdentifierDownloadImage"
        static let openMediaInNewWindow = "WKMenuItemIdentifierOpenMediaInNewWindow"
        static let downloadMedia = "WKMenuItemIdentifierDownloadMedia"
        static let openFrameInNewWindow = "WKMenuItemIdentifierOpenFrameInNewWindow"
    }

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        pendingLinkTarget = nil
        guard let element = contextElement, Date().timeIntervalSince(element.time) < 3,
              let items = contextItems?(self, element) else {
            rewriteWithoutElement(menu)
            return
        }
        contextElement = nil
        Self.rewrite(menu, with: items)
        // An image with no link reported, inside a link the page couldn't report.
        if items.openLink.isEmpty { rewriteWithoutElement(menu) }
    }

    /// No report from the page: if WebKit's menu is for a link, its "Open Link in New Window"
    /// gives way to the app's items, which run it with a target set.
    private func rewriteWithoutElement(_ menu: NSMenu) {
        guard let webKitItem = menu.items.first(where: { $0.identifier?.rawValue == Identifier.openLinkInNewWindow }),
              let action = webKitItem.action,
              let items = fallbackLinkItems?(self, { [weak self, weak webKitItem] space in
                  guard let self, let webKitItem else { return }
                  self.pendingLinkTarget = (space, Date())
                  NSApp.sendAction(action, to: webKitItem.target, from: webKitItem)
              }), !items.isEmpty else { return }
        // Hidden, not removed: WebKit's action reads the item, which stays in its menu.
        let index = menu.index(of: webKitItem)
        webKitItem.isHidden = true
        for (offset, item) in items.enumerated() { menu.insertItem(item, at: index + 1 + offset) }
    }

    /// Swaps WebKit's items for the app's, keeping their place in the menu.
    static func rewrite(_ menu: NSMenu, with items: ContextMenuItems) {
        func replace(_ identifier: String, with replacement: [NSMenuItem]) -> Bool {
            guard let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == identifier }) else { return false }
            menu.removeItem(at: index)
            for (offset, item) in replacement.enumerated() { menu.insertItem(item, at: index + offset) }
            return true
        }
        if !items.openLink.isEmpty, !replace(Identifier.openLinkInNewWindow, with: items.openLink) {
            // A WebKit without the identifier: put them first.
            for (offset, item) in items.openLink.enumerated() { menu.insertItem(item, at: offset) }
            menu.insertItem(.separator(), at: items.openLink.count)
        }
        if let item = items.downloadLink { _ = replace(Identifier.downloadLinkedFile, with: [item]) }
        if let item = items.openImage { _ = replace(Identifier.openImageInNewWindow, with: [item]) }
        if let item = items.saveImage { _ = replace(Identifier.downloadImage, with: [item]) }
        // New windows don't exist in iSmith; media and frames open as tabs through the same path
        // as links would, so WebKit's remaining "new window" items are dropped.
        for id in [Identifier.openMediaInNewWindow, Identifier.openFrameInNewWindow, Identifier.downloadMedia] {
            if let index = menu.items.firstIndex(where: { $0.identifier?.rawValue == id }) { menu.removeItem(at: index) }
        }
        // No doubled or trailing separators after the edits.
        var previousWasSeparator = true
        for item in menu.items {
            if item.isSeparatorItem, previousWasSeparator { menu.removeItem(item) } else { previousWasSeparator = item.isSeparatorItem }
        }
        if menu.items.last?.isSeparatorItem == true { menu.removeItem(at: menu.items.count - 1) }
    }

    /// The script that reports the element under a context menu (iSmith's world, every frame).
    static let contextScript = """
    (() => {
      addEventListener("contextmenu", (e) => {
        if (!e.isTrusted) return;
        let link = null, image = null;
        for (let n = e.target; n && n.nodeType === 1; n = n.parentElement) {
          if (!link && (n.tagName === "A" || n.tagName === "AREA") && n.href) link = String(n.href);
          if (!image && n.tagName === "IMG") image = n.currentSrc || n.src || null;
          if (!link && n.namespaceURI === "http://www.w3.org/2000/svg" && n.tagName === "a" && n.href) {
            try { link = new URL(n.href.baseVal, document.baseURI).href; } catch (_) {}
          }
        }
        try { window.webkit.messageHandlers.ismithContext.postMessage({ link, image }); } catch (_) {}
      }, true);
      // The first real edit in this page (typing, paste, drop, dictation) keeps the tab from
      // hibernating until it loads again.
      let edited = false;
      addEventListener("input", (e) => {
        if (edited || !e.isTrusted) return;
        edited = true;
        try { window.webkit.messageHandlers.ismithContext.postMessage({ edited: true }); } catch (_) {}
      }, true);
    })();
    """
    static let contextHandler = "ismithContext"
}

/// Receives the context script's reports.
final class ContextMenuReporter: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let webView = message.webView as? BrowserWebView, let body = message.body as? [String: Any] else { return }
            if body["edited"] as? Bool == true {
                webView.editedSinceLoad = true
                return
            }
            let url = { (key: String) -> URL? in
                // A data: image can be megabytes; it's saved through WebKit, which has it already.
                guard let s = body[key] as? String, s.count < 1_000_000, let url = URL(string: s), url.scheme != nil else { return nil }
                return url
            }
            webView.contextElement = BrowserWebView.ContextElement(link: url("link"), image: url("image"))
        }
    }
}
