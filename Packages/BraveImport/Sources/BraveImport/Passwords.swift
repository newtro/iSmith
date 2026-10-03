import Foundation

/// A saved password, independent of Brave's format. The app moves these into its own store.
public struct ImportedLogin: Equatable, Sendable {
    /// Which of the profile's login databases held it.
    public enum Store: String, Equatable, Hashable, Sendable {
        /// `Login Data`: passwords saved on this Mac.
        case profile
        /// `Login Data For Account`: passwords saved to the signed-in account.
        case account
    }

    /// Chromium's `PasswordForm::Scheme`. Web forms are `.html`; the others are HTTP auth.
    public enum Scheme: Int, Equatable, Sendable {
        case html = 0, basic = 1, digest = 2, other = 3, usernameOnly = 4
    }

    /// The page the password was saved on (`origin_url`), such as `https://example.com/login`.
    public var origin: String
    /// What Chromium matches on (`signon_realm`): usually the scheme and host, such as
    /// `https://example.com/`; for HTTP auth it also names the realm.
    public var signonRealm: String
    /// Where the form posted to, when known.
    public var actionURL: String?
    public var username: String
    public var password: String
    public var scheme: Scheme
    public var dateCreated: Date?
    public var dateLastUsed: Date?
    public var datePasswordModified: Date?
    public var timesUsed: Int
    /// Every store the login was found in (a login saved to both is imported once).
    public var stores: Set<Store>

    public init(origin: String, signonRealm: String, actionURL: String?, username: String, password: String,
                scheme: Scheme, dateCreated: Date?, dateLastUsed: Date?, datePasswordModified: Date?,
                timesUsed: Int, stores: Set<Store>) {
        self.origin = origin
        self.signonRealm = signonRealm
        self.actionURL = actionURL
        self.username = username
        self.password = password
        self.scheme = scheme
        self.dateCreated = dateCreated
        self.dateLastUsed = dateLastUsed
        self.datePasswordModified = datePasswordModified
        self.timesUsed = timesUsed
        self.stores = stores
    }
}

public struct PasswordImport: Sendable {
    /// A row that couldn't be decrypted. It is left out of `logins`; the app can list these.
    public struct Failure: Equatable, Sendable {
        public var store: ImportedLogin.Store
        public var origin: String
        public var username: String
        public var reason: PasswordDecryptionError
    }

    /// Imported logins, `Login Data` first then `Login Data For Account`, each in saved order,
    /// with logins present in both stores merged into one.
    public var logins: [ImportedLogin]
    /// Rows the user marked "Never save" for a site. They have no password and are skipped.
    public var skippedNeverSave: Int
    public var failures: [Failure]
}

public enum PasswordImportError: Error, Equatable {
    /// Every encrypted password failed to decrypt, so the Safe Storage key is wrong (for example
    /// a Keychain item from another install). Nothing is imported rather than nothing but errors.
    case wrongKey
}

/// Reads a Brave profile's saved passwords.
///
/// Both login databases are copied into a private temporary folder (Brave holds them locked),
/// read there, and the copies are deleted before returning. Brave's files are only ever read.
/// The "Brave Safe Storage" password is asked for at most once per reader, and only when there
/// is something encrypted to read, so macOS's Keychain prompt appears once per import.
public final class BravePasswordReader {
    private let passwordSource: SafeStoragePasswordSource
    private let temporaryDirectory: URL
    private var cipher: ChromiumPasswordCipher?

    public init(passwordSource: SafeStoragePasswordSource,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.passwordSource = passwordSource
        self.temporaryDirectory = temporaryDirectory
    }

    public func read(profile: BraveProfile) throws -> PasswordImport {
        try read(loginData: profile.loginDataURL, accountLoginData: profile.accountLoginDataURL)
    }

    /// Reads the two databases; either may be missing (a profile that never saved to the account).
    public func read(loginData: URL?, accountLoginData: URL?) throws -> PasswordImport {
        let work = temporaryDirectory.appendingPathComponent("BraveImport-\(UUID().uuidString)", isDirectory: true)
        try LoginDatabase.makePrivateDirectory(work)
        defer { try? FileManager.default.removeItem(at: work) }

        var sources: [(ImportedLogin.Store, [RawLogin])] = []
        for (store, url) in [(ImportedLogin.Store.profile, loginData), (.account, accountLoginData)] {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { continue }
            sources.append((store, try LoginDatabase.readRows(copyOf: url, workDirectory: work)))
        }

        var logins: [ImportedLogin] = []
        var index: [MergeKey: Int] = [:]
        var neverSave = 0
        var failures: [PasswordImport.Failure] = []
        var encrypted = 0
        var encryptedFailures = 0
        for (store, rows) in sources {
            for row in rows {
                if row.neverSave {
                    neverSave += 1
                    continue
                }
                let password: String
                let isEncrypted = ChromiumPasswordCipher.isEncrypted(row.passwordValue)
                if isEncrypted { encrypted += 1 }
                do {
                    password = try decrypt(row.passwordValue)
                } catch let reason as PasswordDecryptionError {
                    if isEncrypted { encryptedFailures += 1 }
                    failures.append(.init(store: store, origin: row.originURL, username: row.username, reason: reason))
                    continue
                }
                let login = ImportedLogin(
                    origin: row.originURL, signonRealm: row.signonRealm,
                    actionURL: row.actionURL.isEmpty ? nil : row.actionURL,
                    username: row.username, password: password,
                    scheme: ImportedLogin.Scheme(rawValue: row.scheme) ?? .other,
                    dateCreated: ChromiumTime.date(microseconds: row.dateCreated),
                    dateLastUsed: ChromiumTime.date(microseconds: row.dateLastUsed),
                    datePasswordModified: ChromiumTime.date(microseconds: row.datePasswordModified),
                    timesUsed: row.timesUsed, stores: [store])
                let key = MergeKey(signonRealm: login.signonRealm, username: login.username, password: login.password)
                if let existing = index[key] {
                    logins[existing].merge(login)
                } else {
                    index[key] = logins.count
                    logins.append(login)
                }
            }
        }
        if encrypted > 0, encryptedFailures == encrypted {
            // The key can't be right; don't keep it for the next profile either.
            cipher = nil
            throw PasswordImportError.wrongKey
        }
        return PasswordImport(logins: logins, skippedNeverSave: neverSave, failures: failures)
    }

    private func decrypt(_ value: Data) throws -> String {
        guard ChromiumPasswordCipher.isEncrypted(value) else {
            // Empty or legacy plain text: no key needed, so no Keychain prompt.
            return try ChromiumPasswordCipher.decodeUnencrypted(value)
        }
        if cipher == nil {
            cipher = try ChromiumPasswordCipher(safeStoragePassword: passwordSource.safeStoragePassword())
        }
        return try cipher!.decrypt(value)
    }

    /// The same login in both stores: Brave shows it once, so it is imported once.
    private struct MergeKey: Hashable {
        var signonRealm: String
        var username: String
        var password: String
    }
}

extension ImportedLogin {
    /// Folds in a duplicate from another store: earliest creation, latest use and change.
    mutating func merge(_ other: ImportedLogin) {
        stores.formUnion(other.stores)
        dateCreated = [dateCreated, other.dateCreated].compactMap { $0 }.min()
        dateLastUsed = [dateLastUsed, other.dateLastUsed].compactMap { $0 }.max()
        datePasswordModified = [datePasswordModified, other.datePasswordModified].compactMap { $0 }.max()
        timesUsed = max(timesUsed, other.timesUsed)
        if actionURL == nil { actionURL = other.actionURL }
    }
}
