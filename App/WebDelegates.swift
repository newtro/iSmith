import AppKit
import BrowserData
import Security
import WebKit

// What pages ask of the browser: new windows, dialogs, permissions, downloads, sign-in
// challenges, app links, and what happens when a page fails or its process dies.

extension BrowserState: WKUIDelegate {
    /// Popups (OAuth windows, target=_blank) open as a tab next to their opener, in its group and
    /// space. WebKit requires the returned view to use the configuration it passes, which carries
    /// the opener's data store; it gets its own preferences so its Keep alive is its own.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let (window, tabs, opener) = owner(of: webView) else { return nil }
        // window.open("msteams:…") opens the app (after asking), not an empty tab.
        if let url = navigationAction.request.url, let scheme = url.scheme?.lowercased(), !scheme.isEmpty,
           !AppLinks.browserSchemes.contains(scheme) {
            openAppLink(url, from: webView, action: navigationAction)
            return nil
        }
        // ⌘-click or a middle click on a target=_blank link: a background tab with no opener, as
        // for an ordinary link.
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url,
           Self.opensInBackground(navigationAction) {
            openTab(in: window, space: tabs.spaceID, url: url, select: navigationAction.modifierFlags.contains(.shift)) { layout, id in
                layout.insert(id, after: opener.id)
            }
            return nil
        }
        let keepAlive = KeepAlive.isAutomatic(navigationAction.request.url)
        configuration.preferences = Self.preferences(keepAlive: keepAlive)
        // WebKit hands over the opener's content controller; the popup gets its own, so its
        // shield and password state are its own. `makeWebView` adds the app's scripts and
        // handlers (and autofill) to it. A popup with no URL yet (window.open('')) is about the
        // opener's site, which then writes into it.
        configuration.userContentController = WKUserContentController()
        prepareBlocking(configuration, host: navigationAction.request.url?.host ?? webView.url?.host)
        let tab = Tab(url: navigationAction.request.url)
        tab.openerID = opener.id
        tab.agentControlled = opener.agentControlled
        tab.agentHandOff = opener.agentHandOff
        hook(tab)
        let popup = makeWebView(configuration)
        applyAgentControl(tab, to: popup)
        tab.attach(popup, keepAlive: keepAlive)
        tabs.add(tab) { $0.insert(tab.id, after: opener.id) }
        // A popup from an agent's background tab stays in the background with it.
        if window.activeSpaceID == tabs.spaceID, !opener.agentControlled || tabs.layout.selected == opener.id {
            selectTab(tab.id, in: tabs)
        }
        return popup
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let (_, tabs, tab) = owner(of: webView) else { return }
        closeTab(tab.id, in: tabs)
    }

    // MARK: JavaScript dialogs

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let done = Once(completionHandler)
        presentDialog(for: webView, PendingDialog(show: { window, finished in
            let alert = Self.alert(title: "\(frame.securityOrigin.displayHost) says", message: message)
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window) { _ in done.run(); finished() }
        }, cancel: { done.run() }))
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let done = Once(completionHandler)
        presentDialog(for: webView, PendingDialog(show: { window, finished in
            let alert = Self.alert(title: "\(frame.securityOrigin.displayHost) says", message: message)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in done.run(response == .alertFirstButtonReturn); finished() }
        }, cancel: { done.run(false) }))
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let done = Once(completionHandler)
        presentDialog(for: webView, PendingDialog(show: { window, finished in
            let alert = Self.alert(title: "\(frame.securityOrigin.displayHost) says", message: prompt)
            let field = NSTextField(string: defaultText ?? "")
            field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
            alert.accessoryView = field
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { response in
                done.run(response == .alertFirstButtonReturn ? field.stringValue : nil)
                finished()
            }
        }, cancel: { done.run(nil) }))
    }

    /// Long page text is cut so an alert can't fill the screen.
    static func alert(title: String, message: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message.count > 2000 ? String(message.prefix(2000)) + "…" : message
        return alert
    }

    // MARK: File uploads

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let done = Once(completionHandler)
        presentDialog(for: webView, PendingDialog(show: { window, finished in
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.canChooseDirectories = parameters.allowsDirectories
            panel.canChooseFiles = true
            panel.message = "Choose a file to upload to \(frame.securityOrigin.displayHost)"
            panel.prompt = "Upload"
            panel.beginSheetModal(for: window) { response in
                done.run(response == .OK ? panel.urls : nil)
                finished()
            }
        }, cancel: { done.run(nil) }))
    }

    // MARK: Camera, microphone, location

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        let permission: SitePermission
        let what: String
        let symbol: String
        switch type {
        case .camera: (permission, what, symbol) = (.camera, "your camera", "video")
        case .microphone: (permission, what, symbol) = (.microphone, "your microphone", "mic")
        case .cameraAndMicrophone: (permission, what, symbol) = (.cameraAndMicrophone, "your camera and microphone", "video")
        @unknown default: return decisionHandler(.deny)
        }
        askPermission(permission, origin: origin, webView: webView, symbol: symbol,
                      message: "\(origin.displayHost) wants to use \(what).") { allowed in
            decisionHandler(allowed ? .grant : .deny)
        }
    }

    @available(macOS 27.0, *)
    func webView(_ webView: WKWebView, requestGeolocationPermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        askPermission(.location, origin: origin, webView: webView, symbol: "location",
                      message: "\(origin.displayHost) wants to know your location.") { allowed in
            decisionHandler(allowed ? .grant : .deny)
        }
    }
}

extension BrowserState: WKNavigationDelegate {
    /// - App links (msteams:, mailto:, …) go to their apps, after asking once per scheme.
    /// - ⌘-click and middle click open a background tab.
    /// - `<a download>` downloads.
    /// - A tab following a link or redirect to a Keep alive page (Outlook, Teams, Gmail) gets a new
    ///   web view with that policy, which loads the same request; WebKit reads the policy only when
    ///   a web view is created. Form posts can't be replayed safely, so they go ahead and the
    ///   policy follows once the tab is in the background.
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        let scheme = url?.scheme?.lowercased() ?? "about"
        guard ["http", "https", "about", "data", "blob"].contains(scheme) else {
            decisionHandler(.cancel)
            if let url { openAppLink(url, from: webView, action: navigationAction) }
            return
        }
        if navigationAction.shouldPerformDownload { return decisionHandler(.download) }
        if navigationAction.targetFrame?.isMainFrame == true, let (_, _, tab) = owner(of: webView) {
            // Going back or forward, reloading, or restoring a tab isn't a new visit in history.
            tab.lastNavigationType = navigationAction.navigationType
            // A newer navigation replaces any load waiting to be tried again.
            tab.retryURL = nil
            // Following a link in the page: the tab is no longer the link another app sent.
            if navigationAction.navigationType == .linkActivated { routing.forget(tab.id) }
        }
        if navigationAction.navigationType == .linkActivated, navigationAction.targetFrame?.isMainFrame == true,
           Self.opensInBackground(navigationAction), let url, let (window, tabs, tab) = owner(of: webView) {
            decisionHandler(.cancel)
            openTab(in: window, space: tabs.spaceID, url: url, select: navigationAction.modifierFlags.contains(.shift)) { layout, id in
                layout.insert(id, after: tab.id)
            }
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true,
           navigationAction.navigationType != .backForward,
           (navigationAction.request.httpMethod ?? "GET").uppercased() == "GET",
           let (_, tabs, tab) = owner(of: webView),
           tab.appliedKeepAlive == false, !tab.isBuilding, !isLinked(tab),
           KeepAlive.isOn(setting: tab.keepAliveSetting, url: url) {
            decisionHandler(.cancel)
            let state = webView.interactionState
            let request = navigationAction.request
            scheduleBuild(tab, space: tabs.spaceID, state: state, load: request)
            return
        }
        // Blocking follows the destination's site, applied once the navigation is allowed and
        // before its request goes out (Blocking INTEGRATION.md §4). Only main-frame navigations:
        // an iframe follows the page's shield.
        if navigationAction.targetFrame?.isMainFrame == true, shields.controller != nil {
            let controller = webView.configuration.userContentController
            let host = url?.host
            Task { @MainActor in
                await self.applyBlocking(to: controller, host: host)
                decisionHandler(.allow)
            }
            return
        }
        decisionHandler(.allow)
    }

    /// ⌘-click or a middle click: the link opens in a new tab in the background (⇧ brings it
    /// forward).
    static func opensInBackground(_ action: WKNavigationAction) -> Bool {
        action.modifierFlags.contains(.command) || action.buttonNumber == 2
    }

    /// Responses WebKit can't show (or marked as attachments) download; PDFs and images show
    /// inline.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let http = navigationResponse.response as? HTTPURLResponse,
           let disposition = http.value(forHTTPHeaderField: "Content-Disposition"),
           disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment") {
            return decisionHandler(.download)
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        trackDownload(download, from: webView)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        trackDownload(download, from: webView)
        // The navigation became a download and never commits: the page on screen keeps its own
        // blocking setting.
        if navigationResponse.isForMainFrame, let (_, _, tab) = owner(of: webView) {
            shields.controller?.applyIfLoaded(to: webView.configuration.userContentController, host: tab.committedHost)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        passwordUI.webViewChanged(webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        passwordUI.webViewChanged(webView)
        guard let (_, tabs, tab) = owner(of: webView) else { return }
        tab.committedHost = webView.url?.host
        tab.certificateProblem = nil
        tab.retryURL = nil
        (webView as? BrowserWebView)?.editedSinceLoad = false
        // Questions from the page that's gone no longer apply.
        let prompts = tab.prompts
        tab.prompts = []
        for prompt in prompts { prompt.answer(.dismissed) }
        if tab.findShown { tab.findResult = nil }
        applyZoom(to: webView, tab: tab)
        if let url = webView.url, ![.backForward, .reload].contains(tab.lastNavigationType) {
            recordVisit(url, title: webView.title, tab: tab, space: tabs.spaceID)
        }
        tab.lastNavigationType = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let (_, tabs, tab) = owner(of: webView), let url = webView.url,
              let title = webView.title, !title.isEmpty else { return }
        try? data?.history.updateTitle(space: tabs.spaceID, url: url, title: title)
        _ = tab
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        // The page on screen is still the committed one: put its blocking setting back, unless a
        // newer navigation replaced this one (it has applied its own).
        if !webView.isLoading, let (_, _, tab) = owner(of: webView) {
            shields.controller?.applyIfLoaded(to: webView.configuration.userContentController, host: tab.committedHost)
        }
        showLoadError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        // A page that has started showing keeps what it shows; only certificate problems on a
        // committed page (rare) get the warning.
        let nsError = error as NSError
        if Self.certificateErrorCodes.contains(nsError.code), nsError.domain == NSURLErrorDomain {
            showLoadError(error, in: webView)
        }
    }

    func webView(_ webView: WKWebView, didReceive challenge: URLAuthenticationChallenge,
                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        switch space.authenticationMethod {
        case NSURLAuthenticationMethodServerTrust:
            // A certificate the user chose to trust on the warning page, for this run only.
            if let trust = space.serverTrust, certificateExceptions.allows(host: space.host, trust: trust) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.performDefaultHandling, nil)
            }
        case NSURLAuthenticationMethodClientCertificate:
            chooseClientCertificate(challenge, webView: webView, completionHandler: completionHandler)
        case NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodNTLM:
            askForCredentials(challenge, webView: webView, completionHandler: completionHandler)
        default:
            // Kerberos (Negotiate) and the rest: the system's handling.
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// The page's web content process died (a crash, or macOS reclaiming memory). The tab shows
    /// a reload state; a Keep alive tab in the background reloads by itself, so mail and calls
    /// keep coming, unless it keeps crashing.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard let (window, tabs, tab) = owner(of: webView) else { return }
        let now = Date()
        tab.crashTimes = tab.crashTimes.filter { now.timeIntervalSince($0) < 300 } + [now]
        tab.crashed = true
        NSLog("iSmith: web content process ended for \(webView.url?.host ?? "a tab")")
        let visible = window.activeSpaceID == tabs.spaceID && tabs.layout.selected == tab.id
        if tab.keepAlive, !visible, tab.crashTimes.count <= Self.maxAutomaticReloads {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self, weak tab] in
                guard let self, let tab, tab.crashed else { return }
                self.reloadAfterCrash(tab)
            }
        }
    }
}

// MARK: - Helpers for the delegates

extension BrowserState {
    static let maxAutomaticReloads = 3
    static let certificateErrorCodes: Set<Int> = [
        NSURLErrorServerCertificateHasBadDate, NSURLErrorServerCertificateUntrusted,
        NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
        NSURLErrorSecureConnectionFailed,
    ]

    func reloadAfterCrash(_ tab: Tab) {
        tab.crashed = false
        guard let webView = tab.webView else { return }
        if webView.url != nil { webView.reload() } else if let url = tab.url { webView.load(URLRequest(url: url)) }
    }

    /// A failed load shows a warning page in the tab: a certificate problem, or a site that
    /// can't be reached. Cancelled loads (a new navigation, a download) show nothing.
    func showLoadError(_ error: Error, in webView: WKWebView) {
        guard let (_, _, tab) = owner(of: webView) else { return }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", [102, 204].contains(nsError.code) { return } // policy change, plug-in
        let url = (nsError.userInfo[NSURLErrorFailingURLErrorKey] as? URL)
            ?? (nsError.userInfo[NSURLErrorFailingURLStringErrorKey] as? String).flatMap(URL.init(string:))
            ?? webView.url ?? tab.url
        guard let url else { return }
        let trust = nsError.userInfo[NSURLErrorFailingURLPeerTrustErrorKey].map { $0 as! SecTrust }
        if nsError.domain == NSURLErrorDomain, Self.certificateErrorCodes.contains(nsError.code) || trust != nil {
            tab.certificateProblem = CertificateProblem(url: url, message: nsError.localizedDescription, trust: trust)
        } else if nsError.domain == NSURLErrorDomain {
            // A tab in the background, or kept alive (Outlook reloading as the Mac wakes), keeps
            // what it shows and tries again when the network is back (or within a minute); one on
            // screen shows why the page didn't open.
            let visible = owner(of: tab).map { $0.0.activeSpaceID == $0.1.spaceID && $0.1.layout.selected == tab.id } ?? false
            if visible, !tab.keepAlive {
                tab.retryURL = nil
                tab.certificateProblem = CertificateProblem(url: url, message: nsError.localizedDescription, trust: nil)
            } else {
                tab.retryURL = url
            }
        }
    }

    /// "Visit This Website" on the certificate warning: trusts that certificate for its host until
    /// the app quits, and loads the page again.
    func proceedDespiteCertificate(_ tab: Tab) {
        guard let problem = tab.certificateProblem, let trust = problem.trust, let host = problem.url.host else { return }
        certificateExceptions.accept(host: host, trust: trust)
        tab.certificateProblem = nil
        tab.webView?.load(URLRequest(url: problem.url))
    }

    // MARK: Dialogs

    /// Shows a dialog for a page as a sheet once its tab is on screen; until then it waits.
    func presentDialog(for webView: WKWebView, _ dialog: PendingDialog) {
        guard let (_, _, tab) = owner(of: webView) else { return dialog.cancel() }
        tab.pendingDialogs.append(dialog)
        showPendingDialogs(of: tab)
    }

    /// Shows the tab's next waiting dialog, if the tab is the one on screen in its window.
    func showPendingDialogs(of tab: Tab) {
        guard !tab.showingDialog, !tab.pendingDialogs.isEmpty, let (window, tabs) = owner(of: tab),
              window.activeSpaceID == tabs.spaceID, tabs.layout.selected == tab.id,
              let nsWindow = window.window, nsWindow.attachedSheet == nil else { return }
        let dialog = tab.pendingDialogs.removeFirst()
        tab.showingDialog = true
        dialog.show(nsWindow) { [weak self, weak tab, weak window] in
            tab?.showingDialog = false
            if let tab { self?.showPendingDialogs(of: tab) }
            // Another tab may have been waiting for this sheet to go.
            if let shown = window?.active?.selected, shown !== tab { self?.showPendingDialogs(of: shown) }
        }
    }

    // MARK: Site prompts

    /// Shows a question as a bar over the tab's page. The same question twice in one tab waits
    /// for the first answer.
    func ask(_ prompt: SitePrompt, in tab: Tab) {
        if let existing = tab.prompts.first(where: { $0.key == prompt.key }) {
            existing.join { prompt.answer($0) }
            return
        }
        tab.prompts.append(prompt)
    }

    func answer(_ prompt: SitePrompt, _ answer: PromptAnswer, in tab: Tab) {
        tab.prompts.removeAll { $0 === prompt }
        prompt.answer(answer)
    }

    /// A per-site permission: the saved answer, or a bar asking (and saving the answer).
    func askPermission(_ permission: SitePermission, origin: WKSecurityOrigin, webView: WKWebView, symbol: String,
                       message: String, decided: @escaping (Bool) -> Void) {
        let key = origin.originKey
        guard !origin.isOpaque else { return decided(false) }
        let saved = SitePermissions.decision(for: permission) { try? self.data?.sites.decision($0, origin: key) }
        if let saved { return decided(saved == .allow) }
        guard let (_, _, tab) = owner(of: webView) else { return decided(false) }
        ask(SitePrompt(key: "permission:\(permission.rawValue):\(key)", symbol: symbol, message: message, allowTitle: "Allow") { [weak self] answer in
            switch answer {
            case .allow:
                try? self?.data?.sites.setDecision(.allow, for: permission, origin: key)
                decided(true)
            case .deny:
                try? self?.data?.sites.setDecision(.deny, for: permission, origin: key)
                decided(false)
            case .dismissed:
                decided(false)
            }
        }, in: tab)
    }

    // MARK: App links

    /// msteams:, mailto: and other app links (see `AppLinks.plan`). A remembered "Don't Open" drops
    /// them; a remembered "Open" opens the app at once only right after a real click or key press
    /// in the page (or in the page that opened this one, such as Outlook's "Join" launcher), from
    /// the page itself or a frame of the same site. Scripted clicks don't count. One question per
    /// scheme at a time, naming the frame that asked; answering opens that one link.
    func openAppLink(_ url: URL, from webView: WKWebView, action: WKNavigationAction?) {
        guard let scheme = url.scheme?.lowercased(), let (_, _, tab) = owner(of: webView) else { return }
        let stored = try? data?.sites.appLinkDecision(scheme: scheme)
        let sourceFrame = action?.sourceFrame as WKFrameInfo?
        let source = sourceFrame?.securityOrigin.host
        let sameSite = sourceFrame?.isMainFrame ?? true || source?.lowercased() == webView.url?.host?.lowercased()
        let clicked = sameSite && hadRecentInput(webView, tab: tab)
        let site = (source?.isEmpty == false ? source : nil) ?? webView.url?.host ?? "This page"
        switch AppLinks.plan(AppLinks.decide(url, stored: stored ?? nil, appFor: AppLinks.defaultApp), clicked: clicked) {
        case .none:
            return
        case .open:
            NSWorkspace.shared.open(url)
        case .noAppNotice:
            guard !tab.prompts.contains(where: { $0.key == "noapp:\(scheme)" }) else { return }
            ask(SitePrompt(key: "noapp:\(scheme)", symbol: "questionmark.app",
                           message: "No app on this Mac opens “\(scheme):” links.", allowTitle: "OK", denyTitle: nil) { _ in }, in: tab)
        case let .ask(_, name, remember):
            // Already asking about this scheme: later requests are dropped, not queued.
            guard !tab.prompts.contains(where: { $0.key == "app:\(scheme)" }) else { return }
            let message = remember
                ? "\(site) wants to open \(name). iSmith will remember your answer for “\(scheme):” links you click."
                : "\(site) wants to open \(name)."
            ask(SitePrompt(key: "app:\(scheme)", symbol: "arrow.up.forward.app", message: message,
                           allowTitle: "Open \(name)", denyTitle: remember ? "Don't Open" : "Not Now") { [weak self] answer in
                switch answer {
                case .allow:
                    if remember { try? self?.data?.sites.setAppLinkDecision(.open, scheme: scheme) }
                    NSWorkspace.shared.open(url)
                case .deny:
                    if remember { try? self?.data?.sites.setAppLinkDecision(.block, scheme: scheme) }
                case .dismissed:
                    break
                }
            }, in: tab)
        }
    }

    /// The user clicked or typed in this page in the last few seconds, or the tab is a popup its
    /// opener opened right after a click.
    func hadRecentInput(_ webView: WKWebView, tab: Tab) -> Bool {
        let now = Date()
        if let input = (webView as? BrowserWebView)?.lastUserInput, now.timeIntervalSince(input) < 3 { return true }
        guard let openerID = tab.openerID, now.timeIntervalSince(tab.createdAt) < 10,
              let opener = windows.flatMap(\.allTabs).first(where: { $0.id == openerID }),
              let input = (opener.webView as? BrowserWebView)?.lastUserInput else { return false }
        return now.timeIntervalSince(input) < 10
    }

    // MARK: Downloads

    func trackDownload(_ download: WKDownload, from webView: WKWebView?, askWhere: Bool = false) {
        let space = webView.flatMap { owner(of: $0)?.1.spaceID } ?? currentWindow?.activeSpaceID ?? ""
        downloads.track(download, space: space, referrer: webView?.url, askWhere: askWhere)
    }

    /// "Download Linked File" and "Save Image As…": downloads through the page's own web view, so
    /// its cookies (the space's sign-ins) apply.
    func startDownload(_ url: URL, from webView: WKWebView, askWhere: Bool) {
        var request = URLRequest(url: url)
        if let page = webView.url, let origin = WebNotifications.originKey(page),
           !(page.scheme == "https" && url.scheme == "http") {
            // The page's origin only (strict-origin-when-cross-origin), never its path.
            request.setValue(origin + "/", forHTTPHeaderField: "Referer")
        }
        webView.startDownload(using: request) { [weak self, weak webView] download in
            self?.trackDownload(download, from: webView, askWhere: askWhere)
        }
    }

    // MARK: Sign-in challenges

    /// HTTP Basic, Digest and NTLM: a sheet asks for a user name and password (kept for the
    /// session only). Cancelling shows the site's own "not authorized" page.
    func askForCredentials(_ challenge: URLAuthenticationChallenge, webView: WKWebView,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let done = Once<(URLSession.AuthChallengeDisposition, URLCredential?)> { completionHandler($0.0, $0.1) }
        let space = challenge.protectionSpace
        presentDialog(for: webView, PendingDialog(show: { window, finished in
            let alert = NSAlert()
            alert.messageText = "Sign in to \(space.host)"
            var info = space.receivesCredentialSecurely ? "" : "Your password will be sent unencrypted. "
            if let realm = space.realm, !realm.isEmpty { info += "The site says: “\(realm)”." }
            if challenge.previousFailureCount > 0 { info = "The user name or password was incorrect. " + info }
            alert.informativeText = info
            let user = NSTextField(string: challenge.proposedCredential?.user ?? "")
            user.placeholderString = "User name"
            let password = NSSecureTextField(string: "")
            password.placeholderString = "Password"
            let stack = NSStackView(views: [user, password])
            stack.orientation = .vertical
            stack.spacing = 8
            stack.frame = NSRect(x: 0, y: 0, width: 260, height: 56)
            user.frame.size.width = 260
            password.frame.size.width = 260
            alert.accessoryView = stack
            alert.addButton(withTitle: "Sign In")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = user.stringValue.isEmpty ? user : password
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    done.run((.useCredential, URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession)))
                } else {
                    done.run((.rejectProtectionSpace, nil))
                }
                finished()
            }
        }, cancel: { done.run((.cancelAuthenticationChallenge, nil)) }))
    }

    /// A site asks for a client certificate: pick one of the Keychain's identities the server
    /// accepts. With none, the connection goes ahead without one.
    func chooseClientCertificate(_ challenge: URLAuthenticationChallenge, webView: WKWebView,
                                 completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let identities = Self.identities(issuers: challenge.protectionSpace.distinguishedNames ?? [])
        guard !identities.isEmpty else { return completionHandler(.performDefaultHandling, nil) }
        let done = Once<(URLSession.AuthChallengeDisposition, URLCredential?)> { completionHandler($0.0, $0.1) }
        let host = challenge.protectionSpace.host
        presentDialog(for: webView, PendingDialog(show: { window, finished in
            let alert = NSAlert()
            alert.messageText = "\(host) asks for a certificate"
            alert.informativeText = "Choose the certificate to identify yourself with."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
            for identity in identities { popup.addItem(withTitle: Self.name(of: identity)) }
            alert.accessoryView = popup
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { response in
                if response == .alertFirstButtonReturn {
                    let identity = identities[max(0, popup.indexOfSelectedItem)]
                    done.run((.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .forSession)))
                } else {
                    // Without a certificate: the site decides what that means.
                    done.run((.performDefaultHandling, nil))
                }
                finished()
            }
        }, cancel: { done.run((.cancelAuthenticationChallenge, nil)) }))
    }

    /// Identities in the Keychain, limited to the issuers the server named (if it named any).
    static func identities(issuers: [Data]) -> [SecIdentity] {
        var query: [String: Any] = [kSecClass as String: kSecClassIdentity,
                                    kSecMatchLimit as String: kSecMatchLimitAll,
                                    kSecReturnRef as String: true]
        if !issuers.isEmpty { query[kSecMatchIssuers as String] = issuers }
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [Any] else { return [] }
        return items.map { $0 as! SecIdentity }
    }

    static func name(of identity: SecIdentity) -> String {
        var certificate: SecCertificate?
        SecIdentityCopyCertificate(identity, &certificate)
        return certificate.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Certificate"
    }
}

/// Site permissions as WebKit asks for them. A request for camera and microphone together is
/// allowed when both are (or the pair is); asking for one alone accepts a saved answer for the
/// pair.
enum SitePermissions {
    static func decision(for permission: SitePermission, saved: (SitePermission) -> PermissionDecision?) -> PermissionDecision? {
        if let exact = saved(permission) { return exact }
        switch permission {
        case .camera, .microphone:
            return saved(.cameraAndMicrophone)
        case .cameraAndMicrophone:
            let camera = saved(.camera), microphone = saved(.microphone)
            if camera == .deny || microphone == .deny { return .deny }
            if camera == .allow, microphone == .allow { return .allow }
            return nil
        default:
            return nil
        }
    }
}

/// Calls a completion handler at most once, whichever of answering or cancelling comes first.
/// WebKit raises an exception if a delegate's handler is never called or called twice.
final class Once<Value> {
    private var handler: ((Value) -> Void)?

    init(_ handler: @escaping (Value) -> Void) {
        self.handler = handler
    }

    func run(_ value: Value) {
        let h = handler
        handler = nil
        h?(value)
    }
}

extension Once where Value == Void {
    convenience init(_ handler: @escaping () -> Void) {
        self.init { (_: Void) in handler() }
    }

    func run() { run(()) }
}
