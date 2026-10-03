import AppKit
import Blocking
import Combine
import SwiftUI
import WebKit

/// Ad and tracker blocking as the UI sees it: the global switch (Settings), and the per-site
/// shield in the toolbar. The `BlockingController` does the work; see
/// `Packages/Blocking/INTEGRATION.md` for the rules this follows.
@MainActor
final class Shields: ObservableObject {
    static let enabledKey = "blockingEnabled"

    /// nil when blocking couldn't be set up (WebKit couldn't open its store); pages load unblocked.
    let controller: BlockingController?
    /// Settings ▸ Privacy ▸ "Block ads and trackers".
    @Published private(set) var enabled: Bool
    /// Bumped when the allowlist or the lists change, so shields redraw.
    @Published private(set) var revision = 0
    /// The web view whose shield was just clicked: it reloads whatever else is going on in it.
    weak var toggledWebView: WKWebView?
    private var observers: [NSObjectProtocol] = []

    init(controller: BlockingController?, defaults: UserDefaults = .standard) {
        self.controller = controller
        enabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        controller?.isEnabled = enabled
        for name in [BlockingController.allowlistDidChange, BlockingController.listsDidChange] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: controller, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.revision += 1 }
            })
        }
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// The site the shield is about: http(s) pages with a host only.
    static func host(of url: URL?) -> String? {
        guard let url, ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host, !host.isEmpty else { return nil }
        return host
    }

    /// The registrable domain shown in the shield ("cnn.com" for www.cnn.com).
    static func site(of host: String) -> String {
        BlockingController.site(for: host) ?? host
    }

    /// Whether ads and trackers are blocked on this page. nil when the shield doesn't apply (no
    /// blocking, or not a web page).
    func isBlocked(_ url: URL?) -> Bool? {
        guard let controller, let host = Self.host(of: url) else { return nil }
        return enabled && controller.isBlocked(host: host)
    }

    /// The toolbar shield: turns blocking off (or back on) for the page's whole site. The
    /// controller posts `allowlistDidChange`; `BrowserState` re-applies and reloads that site's tabs.
    func toggle(for url: URL?) throws {
        guard let controller, enabled, let host = Self.host(of: url) else { return }
        try controller.setAllowed(host: host, controller.isBlocked(host: host))
    }

    /// The global switch. Takes effect from each page's next load.
    func setEnabled(_ on: Bool, defaults: UserDefaults = .standard) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        controller?.isEnabled = on
        if on {
            startLoading()
        } else {
            controller?.stopAutomaticRefresh()
        }
        revision += 1
    }

    /// Loads (on a first launch, converts and compiles) the lists in the background, and starts
    /// the weekly refresh. Nothing here waits on the main thread: conversion runs on a background
    /// task and WebKit compiles off the main thread.
    func startLoading() {
        guard let controller, enabled else { return }
        Task { _ = await controller.ruleLists() }
        controller.startAutomaticRefresh()
    }

    var allowedSites: [String] { controller?.allowedSites ?? [] }

    func allow(_ site: String, _ allowed: Bool) throws {
        try controller?.setAllowed(host: site, allowed)
    }

    /// "EasyList 202610030410 · EasyPrivacy 202610030402, checked 2 days ago", or the last error.
    var statusLine: String {
        guard let controller else { return "Blocking couldn't start: WebKit couldn't open its rule store." }
        let status = controller.status
        if let error = status.lastError { return error }
        let names = ["easylist": "EasyList", "easyprivacy": "EasyPrivacy"]
        let versions = status.listVersions.sorted { $0.key < $1.key }
            .map { "\(names[$0.key] ?? $0.key) \($0.value)" }.joined(separator: " · ")
        let source = status.origin == .downloaded ? "downloaded" : "built in"
        var line = versions.isEmpty ? "Filter lists not loaded yet" : "\(versions) (\(source))"
        if let checked = status.lastChecked {
            line += ", checked \(RelativeDateTimeFormatter().localizedString(for: checked, relativeTo: Date()))"
        }
        return line
    }
}

// MARK: - Wiring into web views

extension BrowserState {
    /// How long a navigation waits for the lists. A normal launch finds them compiled in well
    /// under a millisecond. A first launch (or the first after an OS update) compiles them for
    /// about 5 s; pages don't wait that long, they load unblocked and get the lists from their
    /// next load (`listsDidChange`).
    static let blockingWait: TimeInterval = 1

    /// Applies the destination's setting once a main-frame navigation is allowed (see
    /// INTEGRATION.md §4). Waits at most `blockingWait` for the lists. Every call goes through
    /// the controller's `apply`, so a newer navigation's setting always wins over an older one
    /// that finishes waiting later.
    func applyBlocking(to controller: WKUserContentController, host: String?) async {
        guard let blocking = shields.controller else { return }
        if blocking.loadedRuleLists != nil || !blocking.isEnabled {
            await blocking.apply(to: controller, host: host)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let once = Once<Void> { continuation.resume() }
            Task { @MainActor in
                await blocking.apply(to: controller, host: host)
                once.run()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.blockingWait) { once.run() }
        }
    }

    /// A new web view's content controller gets the lists before its first load (a restored
    /// history loads without asking the navigation delegate first in some WebKit versions).
    func prepareBlocking(_ configuration: WKWebViewConfiguration, host: String?) {
        shields.controller?.applyIfLoaded(to: configuration.userContentController, host: host)
    }

    /// Every open web view, in every window and space.
    var openWebViews: [WKWebView] { windows.flatMap(\.allTabs).compactMap(\.webView) }

    /// Watches the controller: new lists (first load, refresh, global switch) are re-applied to
    /// open pages for their next load; an allowlist change re-applies and reloads that site's tabs.
    func observeBlocking() -> [NSObjectProtocol] {
        guard let controller = shields.controller else { return [] }
        let center = NotificationCenter.default
        let lists = center.addObserver(forName: BlockingController.listsDidChange, object: controller, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for webView in self.openWebViews {
                    controller.applyIfLoaded(to: webView.configuration.userContentController, host: webView.url?.host)
                }
            }
        }
        let allowlist = center.addObserver(forName: BlockingController.allowlistDidChange, object: controller, queue: .main) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, let site = note.userInfo?["site"] as? String else { return }
                let clicked = self.shields.toggledWebView
                self.shields.toggledWebView = nil
                for webView in self.openWebViews {
                    guard let host = webView.url?.host, BlockingController.site(for: host) ?? host == site else { continue }
                    controller.applyIfLoaded(to: webView.configuration.userContentController, host: host)
                    // Other tabs of the site reload only when nothing would be lost: not a Keep
                    // alive tab (Outlook, a Teams call), a popup or its opener mid-sign-in, or a
                    // page with unsaved edits. Those get the new setting on their next load.
                    if webView === clicked || self.canReloadForShield(webView) { webView.reload() }
                }
            }
        }
        return [lists, allowlist]
    }

    func canReloadForShield(_ webView: WKWebView) -> Bool {
        guard let (_, _, tab) = owner(of: webView), !tab.keepAlive, !isLinked(tab), tab.passwordOffer == nil else { return false }
        return (webView as? BrowserWebView)?.editedSinceLoad != true
    }

    /// The shield button's action for a tab.
    func toggleBlocking(for tab: Tab) {
        shields.toggledWebView = tab.webView
        do {
            try shields.toggle(for: tab.webView?.url ?? tab.url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "The blocking setting couldn't be saved"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

// MARK: - Toolbar shield

/// The shield in the address bar: filled when ads and trackers are blocked on the site, slashed
/// when they're allowed. Clicking switches it for the whole site and reloads its tabs.
struct ShieldButton: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var shields: Shields
    @ObservedObject var tab: Tab

    var body: some View {
        let url = tab.url
        if let blocked = shields.isBlocked(url), let host = Shields.host(of: url) {
            let site = Shields.site(of: host)
            Button { browser.toggleBlocking(for: tab) } label: {
                Image(systemName: blocked ? "shield.lefthalf.filled" : "shield.slash")
                    .foregroundStyle(blocked ? Color.accentColor : Color.secondary)
            }
            .help(blocked ? "Blocking ads and trackers on \(site). Click to allow them on this site."
                          : "Ads and trackers are allowed on \(site). Click to block them.")
            .accessibilityLabel(blocked ? "Blocking on \(site)" : "Blocking off for \(site)")
            .id(shields.revision)
        } else if shields.controller != nil, !shields.enabled, Shields.host(of: url) != nil {
            Image(systemName: "shield.slash")
                .foregroundStyle(.tertiary)
                .help("Ad and tracker blocking is off in Settings ▸ Privacy")
                .accessibilityLabel("Blocking is off")
        }
    }
}

// MARK: - Settings

struct PrivacySettings: View {
    @EnvironmentObject private var browser: BrowserState
    @ObservedObject var shields: Shields
    @State private var updating = false
    @State private var updateResult: String?

    var body: some View {
        Form {
            Section {
                Toggle("Block ads and trackers", isOn: Binding(get: { shields.enabled }, set: { shields.setEnabled($0) }))
                Text("EasyList and EasyPrivacy, refreshed weekly. Changes apply to pages as they load.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Filter lists") {
                    Text(shields.statusLine).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                }
                .id(shields.revision)
                HStack {
                    Button(updating ? "Updating…" : "Update Now") { update() }
                        .disabled(updating || shields.controller == nil || !shields.enabled)
                    if let updateResult { Text(updateResult).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Section("Sites where ads and trackers are allowed") {
                let sites = shields.allowedSites
                if sites.isEmpty {
                    Text("None. Use the shield in the address bar to allow a site.").foregroundStyle(.secondary)
                }
                ForEach(sites, id: \.self) { site in
                    HStack {
                        Text(site)
                        Spacer()
                        Button { try? shields.allow(site, false) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Block ads and trackers on \(site) again")
                    }
                }
            }
            .id(shields.revision)
        }
        .formStyle(.grouped)
    }

    private func update() {
        guard let controller = shields.controller else { return }
        updating = true
        updateResult = nil
        Task {
            let result = await controller.refresh(force: true)
            updating = false
            switch result {
            case .updated: updateResult = "Updated."
            case .unchanged: updateResult = "Already up to date."
            case .notDue: updateResult = "Not due."
            case .failed(let why): updateResult = "Failed: \(why)"
            }
        }
    }
}
