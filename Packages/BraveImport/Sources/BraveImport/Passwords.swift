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
    /// The note saved with the password in Brave's password manager, if any.
    public var note: String?
    public var scheme: Scheme
    public var dateCreated: Date?
    public var dateLastUsed: Date?
    public var datePasswordModified: Date?
    public var timesUsed: Int
    /// Every store the login was found in (a login saved to both is imported once).
    public var stores: Set<Store>

    public init(origin: String, signonRealm: String, actionURL: String?, username: String, password: String,
                note: String? = nil, scheme: Scheme, dateCreated: Date?, dateLastUsed: Date?,
                datePasswordModified: Date?, timesUsed: Int, stores: Set<Store>) {
        self.origin = origin
        self.signonRealm = signonRealm
        self.actionURL = actionURL
        self.username = username
        self.password = password
        self.note = note
        self.scheme = scheme
        self.dateCreated = dateCreated
        self.dateLastUsed = dateLastUsed
        self.datePasswordModified = datePasswordModified
        self.timesUsed = timesUsed
        self.stores = stores
    }
}

public struct PasswordImport: Sendable {
    /// Something that couldn't be decrypted. A password that fails leaves its login out of
    /// `logins`; a note that fails leaves the login in, without its note. The app can list these.
    public struct Failure: Equatable, Sendable {
        public enum Part: Equatable, Sendable { case password, note }

        public var store: ImportedLogin.Store
        public var origin: String
        public var username: String
        public var part: Part
        public var reason: PasswordDecryptionError

        public init(store: ImportedLogin.Store, origin: String, username: String, part: Part,
                    reason: PasswordDecryptionError) {
            self.store = store
            self.origin = origin
            self.username = username
            self.part = part
            self.reason = reason
        }
    }

    /// Imported logins, `Login Data` first then `Login Data For Account`, each in saved order,
    /// with the same login (site, username and password) merged into one, as Brave shows it.
    public var logins: [ImportedLogin]
    /// Rows the user marked "Never save" for a site. They have no password and are skipped.
    public var skippedNeverSave: Int
    public var failures: [Failure]

    public init(logins: [ImportedLogin], skippedNeverSave: Int, failures: [Failure]) {
        self.logins = logins
        self.skippedNeverSave = skippedNeverSave
        self.failures = failures
    }
}

public enum PasswordImportError: Error, Equatable {
    /// Every encrypted password (two or more) failed to decrypt, so the Safe Storage key is wrong
    /// (for example a Keychain item from another install). Thrown rather than returning nothing
    /// but failures.
    case wrongKey
}

/// Reads a Brave profile's saved passwords.
///
/// Both login databases are copied into a private temporary folder (Brave holds them locked),
/// read there, and the copies are deleted before anything is decrypted. Brave's files are only
/// ever read. The "Brave Safe Storage" password is asked for at most once per reader, and only
/// when there is something encrypted to read, so macOS's Keychain prompt appears once per import.
///
/// Reading is synchronous and waits while macOS shows its Keychain prompt, so call it off the
/// main thread.
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
    /// A database that can't be looked at (macOS privacy protection) throws
    /// `BraveAccessError.permissionDenied` rather than counting as missing.
    public func read(loginData: URL?, accountLoginData: URL?) throws -> PasswordImport {
        let work = temporaryDirectory.appendingPathComponent("BraveImport-\(UUID().uuidString)", isDirectory: true)
        try LoginDatabase.makePrivateDirectory(work)
        defer { try? FileManager.default.removeItem(at: work) }

        var sources: [(ImportedLogin.Store, [RawLogin])] = []
        for (store, url) in [(ImportedLogin.Store.profile, loginData), (.account, accountLoginData)] {
            guard let url, let rows = try LoginDatabase.readRows(copyOf: url, workDirectory: work) else { continue }
            sources.append((store, rows))
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
                    failures.append(.init(store: store, origin: row.originURL, username: row.username,
                                          part: .password, reason: reason))
                    continue
                }
                var note: String?
                if let noteValue = row.noteValue {
                    do {
                        note = try decrypt(noteValue)
                    } catch let reason as PasswordDecryptionError {
                        failures.append(.init(store: store, origin: row.originURL, username: row.username,
                                              part: .note, reason: reason))
                    }
                }
                let login = ImportedLogin(
                    origin: row.originURL, signonRealm: row.signonRealm,
                    actionURL: row.actionURL.isEmpty ? nil : row.actionURL,
                    username: row.username, password: password, note: note?.isEmpty == true ? nil : note,
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
        // One damaged value proves nothing about the key; two or more that all fail do.
        if encrypted >= 2, encryptedFailures == encrypted {
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

    /// The same login twice (in both stores, or twice in one store from different forms): Brave
    /// shows it once, so it is imported once.
    private struct MergeKey: Hashable {
        var signonRealm: String
        var username: String
        var password: String
    }
}

extension ImportedLogin {
    /// Folds in a duplicate: earliest creation, latest use and change, and any note or form
    /// address the first copy lacked.
    mutating func merge(_ other: ImportedLogin) {
        stores.formUnion(other.stores)
        dateCreated = [dateCreated, other.dateCreated].compactMap { $0 }.min()
        dateLastUsed = [dateLastUsed, other.dateLastUsed].compactMap { $0 }.max()
        datePasswordModified = [datePasswordModified, other.datePasswordModified].compactMap { $0 }.max()
        timesUsed = max(timesUsed, other.timesUsed)
        if actionURL == nil { actionURL = other.actionURL }
        if note == nil { note = other.note }
    }
}
