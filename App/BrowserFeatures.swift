import AppKit
import BrowserData
import WebKit

/// Viewing features on top of tabs: scripts every web view gets, the link context menu,
/// hibernation, zoom, find and print.
extension BrowserState {
    // MARK: - Scripts

    /// The notification shim and the context-menu reporter, once per content controller (a popup
    /// shares its opener's).
    func configure(_ controller: WKUserContentController) {
        notifications.install(in: controller)
        guard !controller.userScripts.contains(where: { $0.source == BrowserWebView.contextScript }) else { return }
        controller.addUserScript(WKUserScript(source: BrowserWebView.contextScript, injectionTime: .atDocumentStart,
                                              forMainFrameOnly: false, in: notifications.world))
        controller.add(contextReporter, contentWorld: notifications.world, name: BrowserWebView.contextHandler)
    }

    // MARK: - Link context menu

    func contextItems(for webView: BrowserWebView, element: BrowserWebView.ContextElement) -> BrowserWebView.ContextMenuItems {
        guard let (window, tabs, tab) = owner(of: webView) else { return .init() }
        var items = BrowserWebView.ContextMenuItems()
        if let link = element.link {
            items.openLink.append(ActionItem("Open Link in New Tab") { [weak self] in
                self?.openTab(in: window, space: tabs.spaceID, url: link, select: false) { layout, id in
                    layout.insert(id, after: tab.id)
                }
            })
            let others = spaces.filter { $0.id != tabs.spaceID }
            if !others.isEmpty {
                let sub = NSMenu()
                for space in others {
                    let item = ActionItem(space.def.name) { [weak self, weak window] in
                        guard let self, let window, let target = self.space(space.id) else { return }
                        self.openTab(in: window, space: target.id, url: link)
                        self.select(target, in: window)
                    }
                    item.image = StripContentView.swatch(Palette.nsColor(space.def.color))
                    sub.addItem(item)
                }
                let item = NSMenuItem(title: "Open Link in Space", action: nil, keyEquivalent: "")
                item.submenu = sub
                items.openLink.append(item)
            }
            if ["http", "https"].contains(link.scheme?.lowercased() ?? "") {
                items.downloadLink = ActionItem("Download Linked File") { [weak self, weak webView] in
                    guard let webView else { return }
                    self?.startDownload(link, from: webView, askWhere: false)
                }
            }
        }
        if let image = element.image {
            if ["http", "https"].contains(image.scheme?.lowercased() ?? "") {
                items.openImage = ActionItem("Open Image in New Tab") { [weak self] in
                    self?.openTab(in: window, space: tabs.spaceID, url: image, select: false) { layout, id in
                        layout.insert(id, after: tab.id)
                    }
                }
            }
            items.saveImage = ActionItem("Save Image As…") { [weak self, weak webView] in
                guard let webView else { return }
                self?.startDownload(image, from: webView, askWhere: true)
            }
        }
        return items
    }

    /// The save panel for "Save Image As…", as a sheet on the page's window.
    func chooseSaveLocation(name: String, webView: WKWebView?) async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.directoryURL = downloads.folder
        panel.canCreateDirectories = true
        let window = webView?.window ?? currentWindow?.window
        let response: NSApplication.ModalResponse
        if let window, window.attachedSheet == nil {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        return response == .OK ? panel.url : nil
    }

    // MARK: - Hibernation

    /// Unloads tabs that have been in the background for `hibernateAfter`, keeping their history:
    /// never Keep alive tabs, a popup and its opener while both are open, a tab with a dialog or
    /// question waiting, or one using the camera or microphone or playing media.
    func hibernateIdleTabs(now: Date = Date()) {
        for window in windows {
            for tabs in window.spaces.values {
                for tab in tabs.ordered {
                    let visible = window.activeSpaceID == tabs.spaceID && tabs.layout.selected == tab.id
                    if visible {
                        tab.lastShown = now
                        continue
                    }
                    guard now.timeIntervalSince(tab.lastShown) >= Self.hibernateAfter, canHibernate(tab),
                          let webView = tab.webView else { continue }
                    webView.requestMediaPlaybackState { [weak self, weak tab, weak webView] state in
                        MainActor.assumeIsolated {
                            guard let self, let tab, let webView, tab.webView === webView, state != .playing,
                                  self.canHibernate(tab), self.owner(of: tab) != nil else { return }
                            NSLog("iSmith: hibernating \(tab.url?.host ?? "a tab")")
                            self.notifications.forget(webView)
                            tab.unload()
                            self.scheduleRefresh()
                        }
                    }
                }
            }
        }
    }

    func canHibernate(_ tab: Tab) -> Bool {
        guard let webView = tab.webView, !tab.keepAlive, !tab.isBuilding, !isLinked(tab),
              tab.pendingDialogs.isEmpty, !tab.showingDialog, tab.prompts.isEmpty else { return false }
        return webView.cameraCaptureState == .none && webView.microphoneCaptureState == .none
    }

    // MARK: - Zoom

    static let zoomSteps: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3]

    /// ⌘+ / ⌘− / ⌘0: steps the page zoom and remembers it for the site; other open tabs on the
    /// same site follow.
    func zoom(_ tab: Tab, by direction: Int) {
        guard let webView = tab.webView, let host = webView.url?.host?.lowercased() else { return }
        let current = webView.pageZoom
        let next: CGFloat
        switch direction {
        case 0: next = 1
        case 1...: next = Self.zoomSteps.first { $0 > current + 0.001 } ?? Self.zoomSteps.last!
        default: next = Self.zoomSteps.last { $0 < current - 0.001 } ?? Self.zoomSteps.first!
        }
        try? data?.sites.setZoom(next == 1 ? nil : Double(next), host: host)
        for other in windows.flatMap(\.allTabs) where other.webView?.url?.host?.lowercased() == host {
            other.webView?.pageZoom = next
            other.zoom = next
        }
    }

    /// The site's saved zoom, applied when a page commits.
    func applyZoom(to webView: WKWebView, tab: Tab) {
        let saved = webView.url?.host.flatMap { try? data?.sites.zoom(host: $0.lowercased()) } ?? nil
        let factor = CGFloat(saved ?? 1)
        if webView.pageZoom != factor { webView.pageZoom = factor }
        tab.zoom = factor
    }

    // MARK: - Find

    /// ⌘F: shows the find bar and focuses it.
    func showFind(in window: WindowState) {
        guard let tab = window.active?.selected else { return }
        tab.findShown = true
        window.findFocusRequests.send()
    }

    /// Finds the next (or previous) match of the find bar's text.
    func find(_ tab: Tab, backwards: Bool = false) {
        guard let webView = tab.webView, !tab.findText.isEmpty else {
            tab.findResult = nil
            return
        }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.caseSensitive = false
        configuration.wraps = true
        let text = tab.findText
        webView.find(text, configuration: configuration) { [weak tab] result in
            guard let tab, tab.findText == text else { return }
            tab.findResult = result.matchFound
        }
    }

    func hideFind(_ tab: Tab) {
        tab.findShown = false
        tab.findResult = nil
        if let webView = tab.webView {
            // Clears the highlighted match.
            webView.evaluateJavaScript("window.getSelection && window.getSelection().removeAllRanges()", in: nil, in: .defaultClient)
            webView.window?.makeFirstResponder(webView)
        }
    }

    // MARK: - Print

    /// ⌘P: the page through the standard print panel, as a sheet.
    func print(_ tab: Tab) {
        guard let webView = tab.webView, let window = webView.window else { return }
        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        let operation = webView.printOperation(with: info)
        operation.jobTitle = tab.title
        // WebKit's print view needs a frame, or pages come out blank.
        operation.view?.frame = webView.bounds
        operation.showsPrintPanel = true
        operation.showsProgressPanel = true
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }
}

/// Before the app has a Notification Center poster (and in tests that don't set one).
@MainActor
final class NoNotificationPoster: WebNotificationPoster {
    func post(_ notification: WebNotification) {}
    func remove(ids: [String]) {}
    func requestAuthorization() {}
}
