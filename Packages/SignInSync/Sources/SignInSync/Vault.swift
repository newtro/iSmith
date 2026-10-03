import Combine
import CryptoKit
import Foundation

/// Provider cookies per account, saved encrypted to Application Support.
///
/// The file is a small JSON envelope, `{"version": 1, "combined": "<base64>"}`, where `combined` is
/// an AES-GCM sealed box (nonce, ciphertext and tag) of the entries as JSON. The 256-bit key lives
/// in a `KeyStore`: the login Keychain in the app, memory in tests.
///
/// A vault file that can't be opened is never lost: it is copied aside first, and when the key
/// itself can't be read (Keychain locked, access denied) nothing is written at all.
@MainActor
public final class Vault: ObservableObject {
    public struct Entry: Codable {
        public var cookies: [CookieRecord]
        public var updated: Date

        public init(cookies: [CookieRecord], updated: Date) {
            self.cookies = cookies
            self.updated = updated
        }
    }

    struct Envelope: Codable {
        var version: Int
        var combined: String
    }

    @Published public private(set) var entries: [String: Entry] = [:]
    public let fileURL: URL
    private var key: SymmetricKey?
    /// False when the key couldn't be read or saved, or an unreadable file couldn't be backed up.
    private var canSave = true

    public init(fileURL: URL, keyStore: KeyStore) {
        self.fileURL = fileURL
        do {
            try SecureFile.prepareDirectory(fileURL.deletingLastPathComponent())
        } catch {
            NSLog("iSmith vault: could not prepare \(fileURL.deletingLastPathComponent().path): \(error)")
        }
        do {
            key = try keyStore.loadKey()
        } catch {
            // The key may come back (an unlocked Keychain, a later "Allow"), so nothing is replaced.
            canSave = false
            NSLog("iSmith vault: the key could not be read (\(error)); running without saving")
            return
        }
        if FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                guard let key else { throw VaultError.noKey }
                entries = try Self.open(Data(contentsOf: fileURL), key: key)
            } catch {
                do {
                    let backup = try SecureFile.backUp(fileURL, reason: "unreadable")
                    NSLog("iSmith vault: vault.json could not be opened (\(error)); saved a copy at \(backup.path), starting empty")
                } catch {
                    canSave = false
                    NSLog("iSmith vault: vault.json could not be opened or backed up (\(error)); it won't be changed")
                }
            }
        }
        if key == nil, canSave {
            let fresh = SymmetricKey(size: .bits256)
            do {
                try keyStore.saveKey(fresh)
                key = fresh
            } catch {
                canSave = false
                NSLog("iSmith vault: the new key could not be saved (\(error)); running without saving")
            }
        }
    }

    /// nil means the account has never been seen; an empty array means it is signed out.
    public func records(for accountID: String) -> [CookieRecord]? { entries[accountID]?.cookies }

    public func set(_ records: [CookieRecord], for accountID: String) {
        entries[accountID] = Entry(cookies: records.sorted { $0.key < $1.key }, updated: Date())
        save()
    }

    public func remove(_ accountID: String) {
        entries[accountID] = nil
        save()
    }

    /// Adds entries saved elsewhere (the spike's vault), keeping their dates.
    public func importEntries(_ imported: [String: Entry]) {
        for (id, entry) in imported {
            entries[id] = Entry(cookies: entry.cookies.sorted { $0.key < $1.key }, updated: entry.updated)
        }
        save()
    }

    /// Whether the account's saved cookies include a signed-in session at a built-in provider.
    public func hasSession(_ accountID: String) -> Bool {
        guard let records = records(for: accountID) else { return false }
        return records.contains { Self.sessionNames.contains($0.name) }
    }

    private static let sessionNames = Set(ProviderDef.builtIns.flatMap { $0.sessionNames ?? [] })

    private func save() {
        guard canSave, let key else { return }
        do {
            try SecureFile.write(Self.seal(entries, key: key), to: fileURL)
        } catch {
            NSLog("iSmith vault save failed: \(error)")
        }
    }

    static func seal(_ entries: [String: Entry], key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(JSONEncoder().encode(entries), using: key)
        guard let combined = box.combined else { throw VaultError.unsealable }
        return try JSONEncoder().encode(Envelope(version: 1, combined: combined.base64EncodedString()))
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> [String: Entry] {
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, let combined = Data(base64Encoded: envelope.combined) else {
            throw VaultError.unknownFormat
        }
        let plain = try AES.GCM.open(AES.GCM.SealedBox(combined: combined), using: key)
        return try JSONDecoder().decode([String: Entry].self, from: plain)
    }
}

enum VaultError: Error {
    case noKey, unsealable, unknownFormat
}

/// Where the vault key is kept.
public protocol KeyStore {
    /// The saved key, or nil when none has been saved yet. Throws when the store can't be read;
    /// the vault then never replaces the key or the file.
    func loadKey() throws -> SymmetricKey?
    func saveKey(_ key: SymmetricKey) throws
}

/// The vault key as a generic password in the file-based login Keychain, readable by this app's
/// signature without a provisioning profile. Unlocks with the Mac login; never synced.
public struct KeychainKeyStore: KeyStore {
    public static let vaultService = "com.scottsmith.ismith.vault-key"

    public let service: String
    public let account: String

    public init(service: String = KeychainKeyStore.vaultService, account: String = "vault") {
        self.service = service
        self.account = account
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: false]
    }

    public func loadKey() throws -> SymmetricKey? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = out as? Data, let raw = Data(base64Encoded: data), raw.count == 32 else {
            throw Failure(status: errSecDecode)
        }
        return SymmetricKey(data: raw)
    }

    public func saveKey(_ key: SymmetricKey) throws {
        let data = key.withUnsafeBytes { Data($0) }.base64EncodedData()
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "iSmith vault key"
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    /// Removes the key. Only tests use this: the vault becomes unreadable without it.
    public func deleteKey() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// A key held in memory, for tests. Shared between vault instances to act like one Keychain.
public final class InMemoryKeyStore: KeyStore {
    public var key: SymmetricKey?

    public init(key: SymmetricKey? = nil) {
        self.key = key
    }

    public func loadKey() throws -> SymmetricKey? { key }
    public func saveKey(_ key: SymmetricKey) throws { self.key = key }
}
