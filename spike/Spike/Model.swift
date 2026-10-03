import SwiftUI

/// An identity provider whose sign-in cookies belong to an account rather than a space.
struct Provider: Hashable, Identifiable {
    let id: String
    /// Cookie domains owned by the provider. A cookie belongs to the provider when its domain
    /// equals one of these or is a subdomain of one.
    let domains: [String]
    /// When set, only these cookie names are shared. Google sets many fast-changing app and
    /// tracking cookies on google.com; only the sign-in session set needs to follow the account.
    var names: Set<String>? = nil

    func tracks(_ cookie: HTTPCookie) -> Bool {
        owns(cookieDomain: cookie.domain) && (names?.contains(cookie.name) ?? true)
    }

    func owns(cookieDomain: String) -> Bool {
        var host = cookieDomain.lowercased()
        if host.hasPrefix(".") { host.removeFirst() }
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    static let microsoft = Provider(id: "Microsoft", domains: [
        "login.microsoftonline.com", "login.microsoft.com", "login.windows.net", "login.live.com",
    ])
    static let google = Provider(id: "Google", domains: ["google.com"], names: [
        "SID", "HSID", "SSID", "APISID", "SAPISID",
        "__Secure-1PSID", "__Secure-3PSID", "__Secure-1PAPISID", "__Secure-3PAPISID",
        "__Secure-1PSIDTS", "__Secure-3PSIDTS",
        "LSID", "__Host-1PLSID", "__Host-3PLSID", "__Host-GAPS", "ACCOUNT_CHOOSER",
    ])
    static let github = Provider(id: "GitHub", domains: ["github.com"])
}

/// One sign-in at one provider. Its provider cookies live in the vault and are shared by every
/// space bound to it.
struct Account: Hashable, Identifiable {
    let id: String
    let provider: Provider
    let name: String
    var label: String { "\(provider.id): \(name)" }
}

/// A workspace with its own WebKit data store, bound to at most one account per provider.
struct Space: Hashable, Identifiable {
    let id: String
    let name: String
    let initials: String
    let color: Color
    let storeID: UUID
    let accounts: [Account]
    let home: URL
}

struct QuickLink: Identifiable {
    let name: String
    let url: URL
    var id: String { name }
}

enum Seed {
    /// `--selftest` runs against separate stores and a separate vault so real sign-ins are untouched.
    static let isSelfTest = CommandLine.arguments.contains("--selftest")
    static let msContoso = Account(id: "ms-contoso", provider: .microsoft, name: "Contoso")
    static let msFabrikam = Account(id: "ms-fabrikam", provider: .microsoft, name: "Fabrikam")
    static let googlePersonal = Account(id: "google-personal", provider: .google, name: "personal")
    static let googleNewtro = Account(id: "google-newtro", provider: .google, name: "Newtro Studios")
    static let githubPersonal = Account(id: "github-personal", provider: .github, name: "personal")
    static let accounts = [msContoso, msFabrikam, googlePersonal, googleNewtro, githubPersonal]

    static let outlook = URL(string: "https://outlook.office.com/mail/")!
    static let gmail = URL(string: "https://mail.google.com/")!
    static let etsy = URL(string: "https://www.etsy.com/your/shops/me/dashboard")!

    // Store identifiers are fixed so each space reopens the same WebKit store on every launch.
    static let spaces: [Space] = [
        Space(id: "contoso", name: "Contoso", initials: "M", color: Color(red: 0.15, green: 0.39, blue: 0.92),
              storeID: storeID("6F1C2A40-0000-4000-8000-000000000001"),
              accounts: [msContoso, googlePersonal, githubPersonal], home: outlook),
        Space(id: "fabrikam", name: "Fabrikam", initials: "TP", color: Color(red: 0.08, green: 0.54, blue: 0.35),
              storeID: storeID("6F1C2A40-0000-4000-8000-000000000002"),
              accounts: [msFabrikam, googlePersonal, githubPersonal], home: outlook),
        Space(id: "contoso-b", name: "Contoso (second space)", initials: "M2", color: Color(red: 0.49, green: 0.23, blue: 0.93),
              storeID: storeID("6F1C2A40-0000-4000-8000-000000000003"),
              accounts: [msContoso], home: outlook),
        Space(id: "personal", name: "Personal", initials: "P", color: Color(red: 0.76, green: 0.42, blue: 0.02),
              storeID: storeID("6F1C2A40-0000-4000-8000-000000000004"),
              accounts: [googlePersonal, githubPersonal], home: gmail),
        Space(id: "newtro", name: "Newtro Studios", initials: "NS", color: Color(red: 0.75, green: 0.07, blue: 0.24),
              storeID: storeID("6F1C2A40-0000-4000-8000-000000000005"),
              accounts: [googleNewtro], home: etsy),
    ]

    private static func storeID(_ base: String) -> UUID {
        UUID(uuidString: isSelfTest ? base.replacingOccurrences(of: "-8000-", with: "-9000-") : base)!
    }

    static let quickLinks: [QuickLink] = [
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
