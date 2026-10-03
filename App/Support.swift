import AppKit
import Foundation
import SignInSync
import SwiftUI

/// Which build this is. Debug builds are "iSmith Dev" (`com.scottsmith.ismith.debug`): their own
/// data folder, WebKit stores, Keychain items and notification settings, so a development run can
/// never read, prompt for or change the installed app's data. Release is `com.scottsmith.ismith`.
enum AppIdentity {
    static let releaseBundleID = "com.scottsmith.ismith"

    /// The running app's bundle id (the app-hosted tests run inside the Debug app).
    static var bundleID: String { Bundle.main.bundleIdentifier ?? releaseBundleID }

    /// "iSmith" or "iSmith Dev", as the menu bar and Dock show it.
    static var displayName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String) ?? "iSmith"
    }

    #if DEBUG
    /// A Debug build never uses the installed app's folder, whatever its bundle id.
    static let dataFolderName = "iSmith Dev"
    static let importsSpike = false
    #else
    static let dataFolderName = "iSmith"
    static let importsSpike = true
    #endif

    /// Keychain services follow the bundle id: `com.scottsmith.ismith.debug.vault-key` is the dev
    /// vault key, and the installed app's `com.scottsmith.ismith.vault-key` is never read by it.
    static var vaultKeyService: String { keychainService("vault-key") }
    static var passwordsKeyService: String { keychainService("passwords-key") }

    static func keychainService(_ name: String) -> String {
        #if DEBUG
        // Belt and braces: a Debug build carrying the release bundle id still stays apart.
        let base = bundleID == releaseBundleID ? releaseBundleID + ".debug" : bundleID
        #else
        let base = bundleID
        #endif
        return "\(base).\(name)"
    }

    /// The vault key store for this build.
    static func vaultKeyStore() -> KeychainKeyStore {
        KeychainKeyStore(service: vaultKeyService, account: "vault", label: "\(displayName) vault key")
    }

    /// The saved-passwords key for this build (the Passwords package's default is the Release
    /// one, so the app always passes this).
    static func passwordsKeyStore() -> KeychainKeyStore {
        KeychainKeyStore(service: passwordsKeyService, account: "passwords", label: "\(displayName) passwords key")
    }
}

/// Where the app keeps its files.
struct AppPaths {
    /// config.json, vault.json, session.json and browser.sqlite.
    let dataDir: URL
    /// The spike's settings, imported on first launch. nil skips the import.
    let spikeDir: URL?

    var configURL: URL { dataDir.appendingPathComponent("config.json") }
    var vaultURL: URL { dataDir.appendingPathComponent("vault.json") }
    /// The open windows, spaces, groups and tabs (see `SessionFile`).
    var sessionURL: URL { dataDir.appendingPathComponent("session.json") }
    /// History, bookmarks, site settings and downloads (the BrowserData package).
    var browserDataURL: URL { dataDir.appendingPathComponent("browser.sqlite") }
    /// Ad and tracker blocking: the compiled lists, the downloaded copies and the allowlist.
    var blockingDir: URL { dataDir.appendingPathComponent("Blocking", isDirectory: true) }
    /// Saved passwords (the Passwords package), encrypted with the passwords key.
    var passwordsURL: URL { dataDir.appendingPathComponent("passwords.sqlite") }
    /// Written once the first-run "Import from Brave" screen has been offered.
    var braveImportOfferedURL: URL { dataDir.appendingPathComponent("brave-import-offered") }

    /// ~/Library/Application Support/iSmith (Release) or ~/Library/Application Support/iSmith Dev
    /// (Debug). `ISMITH_DATA_DIR` points the app at another folder; that folder starts fresh
    /// rather than importing the spike. Debug builds never import the spike.
    static var standard: AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let dir = ProcessInfo.processInfo.environment["ISMITH_DATA_DIR"], !dir.isEmpty {
            return AppPaths(dataDir: URL(fileURLWithPath: dir, isDirectory: true), spikeDir: nil)
        }
        return AppPaths(dataDir: support.appendingPathComponent(AppIdentity.dataFolderName, isDirectory: true),
                        spikeDir: AppIdentity.importsSpike ? support.appendingPathComponent("iSmithSpike", isDirectory: true) : nil)
    }
}

enum Palette {
    static let names = ["Blue", "Green", "Purple", "Amber", "Crimson", "Teal", "Pink", "Slate"]
    private static let rgb: [(Double, Double, Double)] = [
        (0.15, 0.39, 0.92), (0.08, 0.54, 0.35), (0.49, 0.23, 0.93), (0.76, 0.42, 0.02),
        (0.75, 0.07, 0.24), (0.06, 0.46, 0.43), (0.86, 0.15, 0.55), (0.39, 0.45, 0.55),
    ]
    static func color(_ index: Int) -> Color {
        Color(nsColor: nsColor(index))
    }

    static func nsColor(_ index: Int) -> NSColor {
        let c = rgb[((index % rgb.count) + rgb.count) % rgb.count]
        return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: 1)
    }
}

/// The search engine the address bar uses (Settings ▸ General).
enum SearchEngine: String, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, brave, kagi, ecosia

    static let defaultsKey = "searchEngine"

    /// The saved choice; Google when none.
    static var current: SearchEngine {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(SearchEngine.init(rawValue:)) ?? .google }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        case .kagi: return "Kagi"
        case .ecosia: return "Ecosia"
        }
    }

    private var base: String {
        switch self {
        case .google: return "https://www.google.com/search"
        case .duckDuckGo: return "https://duckduckgo.com/"
        case .bing: return "https://www.bing.com/search"
        case .brave: return "https://search.brave.com/search"
        case .kagi: return "https://kagi.com/search"
        case .ecosia: return "https://www.ecosia.org/search"
        }
    }

    func searchURL(_ query: String) -> URL? {
        var parts = URLComponents(string: base)!
        parts.queryItems = [URLQueryItem(name: "q", value: query)]
        return parts.url
    }
}

/// What the address bar opens for what was typed: a URL as given, a bare host (over https, or
/// http for local names such as `localhost:3000`), and anything else as a search.
enum AddressInput {
    static func url(for input: String, engine: SearchEngine = .current) -> URL? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains("://") || text.lowercased().hasPrefix("about:") {
            return URL(string: text)
        }
        if looksLikeAddress(text) {
            return URL(string: (isLocal(text) ? "http://" : "https://") + text)
        }
        return engine.searchURL(text)
    }

    /// "github.com", "dev.azure.com/contoso-dev", "localhost:8080/x", "10.0.0.5": no spaces, and
    /// a dot or a port or localhost.
    static func looksLikeAddress(_ text: String) -> Bool {
        guard !text.contains(" "), let first = text.first, first != "." , first != "?" else { return false }
        let host = hostPart(text)
        if host.lowercased() == "localhost" { return true }
        if host.contains("."), !host.hasSuffix(".") { return true }
        // "intranet:8080"
        if let colon = host.firstIndex(of: ":"), host[host.index(after: colon)...].allSatisfy(\.isNumber),
           host.index(after: colon) < host.endIndex { return true }
        return false
    }

    private static func hostPart(_ text: String) -> String {
        String(text.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
    }

    /// Local development hosts open over http.
    static func isLocal(_ text: String) -> Bool {
        var host = hostPart(text).lowercased()
        if let colon = host.lastIndex(of: ":"), !host.contains("]") { host = String(host[..<colon]) }
        return host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".test") || host.hasSuffix(".local")
            || host == "127.0.0.1" || host == "[::1]"
    }
}

extension GroupColor {
    var nsColor: NSColor { NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
    var color: Color { Color(nsColor: nsColor) }
}
