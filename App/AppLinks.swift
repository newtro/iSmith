import AppKit
import BrowserData
import Foundation

/// Links that open another app: `msteams:`, `ms-word:`, `mailto:`, `zoommtg:` and the like. The
/// first link of a scheme asks "Open in Microsoft Teams?"; the answer is remembered for the scheme
/// (Settings ▸ Websites can forget it). The app opens the link through Launch Services.
enum AppLinks {
    /// Schemes the browser handles itself, or never hands to another app.
    static let browserSchemes: Set<String> = [
        "http", "https", "about", "data", "blob", "javascript", "file", "ftp", "ws", "wss",
        "webkit", "x-apple-data-detectors", "applewebdata",
    ]

    enum Action: Equatable {
        /// Not an app link; the browser deals with it.
        case browser
        /// Open it in `app` now (remembered "Open").
        case open(app: URL)
        /// Ask first, naming `app`.
        case ask(app: URL, name: String)
        /// Remembered "Don't Open": drop it.
        case block
        /// No installed app opens it.
        case noApp
    }

    /// What to do with a navigation to `url`. `appFor` finds the app Launch Services would use;
    /// `ownApp` is iSmith itself, which never counts as the app for a link.
    static func decide(_ url: URL, stored: AppLinkDecision?, appFor: (URL) -> URL?, ownApp: URL? = Bundle.main.bundleURL) -> Action {
        guard let scheme = url.scheme?.lowercased(), !browserSchemes.contains(scheme) else { return .browser }
        if stored == .block { return .block }
        guard let app = appFor(url), app.standardizedFileURL != ownApp?.standardizedFileURL else { return .noApp }
        if stored == .open { return .open(app: app) }
        return .ask(app: app, name: appName(app))
    }

    static func appName(_ app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// The app Launch Services would open `url` with.
    static func defaultApp(for url: URL) -> URL? {
        NSWorkspace.shared.urlForApplication(toOpen: url)
    }
}
