import AppKit
import Foundation
import SwiftUI

/// Where the app keeps its files.
struct AppPaths {
    /// config.json, vault.json and session.json.
    let dataDir: URL
    /// The spike's settings, imported on first launch. nil skips the import.
    let spikeDir: URL?

    var configURL: URL { dataDir.appendingPathComponent("config.json") }
    var vaultURL: URL { dataDir.appendingPathComponent("vault.json") }
    /// The open windows, spaces, groups and tabs (see `SessionFile`).
    var sessionURL: URL { dataDir.appendingPathComponent("session.json") }

    /// ~/Library/Application Support/iSmith. For development, `ISMITH_DATA_DIR` points the app at
    /// another folder; that folder starts fresh rather than importing the spike.
    static var standard: AppPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        if let dir = ProcessInfo.processInfo.environment["ISMITH_DATA_DIR"], !dir.isEmpty {
            return AppPaths(dataDir: URL(fileURLWithPath: dir, isDirectory: true), spikeDir: nil)
        }
        return AppPaths(dataDir: support.appendingPathComponent("iSmith", isDirectory: true),
                        spikeDir: support.appendingPathComponent("iSmithSpike", isDirectory: true))
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

struct QuickLink: Identifiable {
    let name: String
    let url: URL
    var id: String { name }

    static let all: [QuickLink] = [
        ("Outlook", "https://outlook.office.com/mail/"),
        ("Azure DevOps", "https://dev.azure.com/contoso-dev"),
        ("Azure portal", "https://portal.azure.com"),
        ("My Microsoft account", "https://myaccount.microsoft.com"),
        ("Gmail", "https://mail.google.com/"),
        ("Google account", "https://myaccount.google.com"),
        ("GitHub", "https://github.com"),
        ("Etsy shop", "https://www.etsy.com/your/shops/me/dashboard"),
    ].map { QuickLink(name: $0.0, url: URL(string: $0.1)!) }
}

/// What the address bar opens for what was typed: a URL as given, a bare host over https, and
/// anything else as a Google search.
enum AddressInput {
    static func url(for input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.contains("://") {
            return URL(string: text)
        } else if text.contains("."), !text.contains(" ") {
            return URL(string: "https://" + text)
        } else {
            var parts = URLComponents(string: "https://www.google.com/search")!
            parts.queryItems = [URLQueryItem(name: "q", value: text)]
            return parts.url
        }
    }
}

extension GroupColor {
    var nsColor: NSColor { NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1) }
    var color: Color { Color(nsColor: nsColor) }
}
