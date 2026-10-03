import CryptoKit
import Foundation
import SignInSync
import XCTest

/// The encrypted vault: what's on disk, what happens when it can't be opened, the Keychain key,
/// and the one-time import from the spike.
@MainActor
final class VaultTests: XCTestCase {
    private var dir: URL!
    private var vaultURL: URL { dir.appendingPathComponent("vault.json") }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func records() -> [CookieRecord] {
        [CookieRecord(cookie("SID", "secret-sid-value", ".google.com", expires: Date().addingTimeInterval(3600))),
         CookieRecord(cookie("ESTSAUTH", "secret-session-value", "login.microsoftonline.com", expires: nil, secure: true, httpOnly: true))]
    }

    private func permissions(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func backups() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("vault.unreadable-") }
    }

    /// A key derived for another use (the app's session file) is stable for the same vault key,
    /// differs by purpose, and is never the vault key itself.
    func testDerivedKeys() throws {
        let keys = InMemoryKeyStore()
        let vault = Vault(fileURL: vaultURL, keyStore: keys)
        let bytes = { (k: SymmetricKey?) in k?.withUnsafeBytes { Data($0) } }
        let history = try XCTUnwrap(vault.derivedKey(purpose: "history"))
        XCTAssertEqual(bytes(Vault(fileURL: vaultURL, keyStore: keys).derivedKey(purpose: "history")), bytes(history))
        XCTAssertNotEqual(bytes(vault.derivedKey(purpose: "other")), bytes(history))
        XCTAssertNotEqual(bytes(keys.key), bytes(history))
    }

    func testRoundTripIsEncryptedOnDisk() throws {
        let keys = InMemoryKeyStore()
        let vault = Vault(fileURL: vaultURL, keyStore: keys)
        XCTAssertNotNil(keys.key, "a first run creates a key")
        vault.set(records(), for: "shared-google")
        vault.set([], for: "ms-fabrikam")

        let raw = try Data(contentsOf: vaultURL)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("secret-sid-value"), "cookie values are not on disk in the clear")
        XCTAssertFalse(text.contains("shared-google"), "account ids are not on disk in the clear")
        let envelope = try JSONSerialization.jsonObject(with: raw) as? [String: Any]
        XCTAssertEqual(envelope?["version"] as? Int, 1)
        XCTAssertNotNil((envelope?["combined"] as? String).flatMap { Data(base64Encoded: $0) }, "sealed box is base64")
        XCTAssertEqual(try permissions(vaultURL), 0o600, "vault file is owner-only")
        XCTAssertEqual(try permissions(dir), 0o700, "vault folder is owner-only")

        let reopened = Vault(fileURL: vaultURL, keyStore: keys)
        XCTAssertEqual(reopened.records(for: "shared-google"), records().sorted { $0.key < $1.key })
        XCTAssertEqual(reopened.records(for: "ms-fabrikam"), [], "a signed-out account stays signed out")
        XCTAssertNil(reopened.records(for: "never-seen"))
        XCTAssertTrue(reopened.hasSession("shared-google"))
        XCTAssertFalse(reopened.hasSession("ms-fabrikam"))
    }

    func testWrongKeyLeavesTheFileUntouchedAndBackedUp() throws {
        Vault(fileURL: vaultURL, keyStore: InMemoryKeyStore()).set(records(), for: "shared-google")
        let original = try Data(contentsOf: vaultURL)

        let other = InMemoryKeyStore(key: SymmetricKey(size: .bits256))
        let vault = Vault(fileURL: vaultURL, keyStore: other)
        XCTAssertTrue(vault.entries.isEmpty, "a vault that can't be opened starts empty")
        XCTAssertEqual(try Data(contentsOf: vaultURL), original, "the unreadable file is untouched")
        let copies = try backups()
        XCTAssertEqual(copies.count, 1, "one timestamped backup")
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, original, "the backup is the original")

        // New sign-ins are saved; the backup stays as it was.
        vault.set(records(), for: "shared-github")
        XCTAssertEqual(try backups().count, 1)
        XCTAssertEqual(try copies.first.map { try Data(contentsOf: $0) }, original)
        XCTAssertEqual(Vault(fileURL: vaultURL, keyStore: other).records(for: "shared-github")?.count, 2)
    }

    func testMissingKeyKeepsTheOldFile() throws {
        Vault(fileURL: vaultURL, keyStore: InMemoryKeyStore()).set(records(), for: "shared-google")
        let original = try Data(contentsOf: vaultURL)
        let keys = InMemoryKeyStore()
        let vault = Vault(fileURL: vaultURL, keyStore: keys)
        XCTAssertTrue(vault.entries.isEmpty)
        XCTAssertNotNil(keys.key, "a new key is made")
        XCTAssertEqual(try backups().map { try Data(contentsOf: $0) }, [original], "the old file is backed up")
    }

    func testUnreadableKeyNeverTouchesTheFile() throws {
        let keys = InMemoryKeyStore()
        Vault(fileURL: vaultURL, keyStore: keys).set(records(), for: "shared-google")
        let original = try Data(contentsOf: vaultURL)

        let vault = Vault(fileURL: vaultURL, keyStore: FailingKeyStore())
        XCTAssertTrue(vault.entries.isEmpty)
        XCTAssertFalse(vault.canSave, "the app is told, so it can stop before syncing")
        XCTAssertNotNil(vault.problem)
        vault.set(records(), for: "shared-github")
        XCTAssertEqual(try Data(contentsOf: vaultURL), original, "nothing is written without the key")
        XCTAssertTrue(try backups().isEmpty, "no backup is needed: the file can still be opened later")
        XCTAssertEqual(Vault(fileURL: vaultURL, keyStore: keys).records(for: "shared-google")?.count, 2)
    }

    func testKeychainKeyStoreRoundTrip() throws {
        // A throwaway item, so the app's real vault key is never touched.
        let store = KeychainKeyStore(service: "com.scottsmith.ismith.tests.\(UUID().uuidString)")
        defer { try? store.deleteKey() }
        XCTAssertNil(try store.loadKey(), "no key before one is saved")
        let key = SymmetricKey(size: .bits256)
        try store.saveKey(key)
        let loaded = try XCTUnwrap(try store.loadKey())
        XCTAssertEqual(loaded.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })

        let vault = Vault(fileURL: vaultURL, keyStore: store)
        vault.set(records(), for: "shared-google")
        XCTAssertEqual(Vault(fileURL: vaultURL, keyStore: store).records(for: "shared-google")?.count, 2)
        XCTAssertThrowsError(try store.saveKey(SymmetricKey(size: .bits256)), "an existing key is never replaced")
        XCTAssertEqual(try store.loadKey()?.withUnsafeBytes { Data($0) }, key.withUnsafeBytes { Data($0) })
        try store.deleteKey()
        XCTAssertNil(try store.loadKey())
    }

    func testKeySavedByAnotherLaunchIsUsedNotReplaced() throws {
        // Two first launches at once: the other one saved its key between our read and our save.
        let theirs = SymmetricKey(size: .bits256)
        let keys = RacingKeyStore(theirs: theirs)
        let vault = Vault(fileURL: vaultURL, keyStore: keys)
        XCTAssertTrue(vault.canSave)
        vault.set(records(), for: "shared-google")
        XCTAssertEqual(Vault(fileURL: vaultURL, keyStore: InMemoryKeyStore(key: theirs)).records(for: "shared-google")?.count, 2,
                       "the vault is sealed with the key that's in the Keychain")
    }

    // MARK: - Spike import

    private func writeSpike(config: String, vault: [String: Vault.Entry]?) throws -> URL {
        let spike = dir.appendingPathComponent("iSmithSpike", isDirectory: true)
        try FileManager.default.createDirectory(at: spike, withIntermediateDirectories: true)
        try config.data(using: .utf8)!.write(to: spike.appendingPathComponent("config.json"))
        if let vault {
            // The spike's format: the entries as plain JSON.
            try JSONEncoder().encode(vault).write(to: spike.appendingPathComponent("vault.json"))
        }
        return spike
    }

    private func snapshot(_ dir: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        for url in try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
            out[url.lastPathComponent] = try Data(contentsOf: url)
        }
        return out
    }

    func testSpikeImport() throws {
        let saved = Date(timeIntervalSince1970: 1_790_000_000)
        let spike = try writeSpike(config: """
            {"version":2,"providers":[],"accounts":[{"id":"ms-fabrikam","providerID":"microsoft","name":"Fabrikam"}],
             "spaces":[{"id":"contoso","name":"Contoso","color":0,"storeID":"6F1C2A40-0000-4000-9000-0000000000B1","bindings":{},"home":""},
                       {"id":"fabrikam","name":"Fabrikam","color":1,"storeID":"6F1C2A40-0000-4000-9000-0000000000B2","bindings":{"microsoft":"ms-fabrikam"},"home":""}],
             "shared":{}}
            """, vault: ["shared-google": Vault.Entry(cookies: records(), updated: saved),
                         "ms-fabrikam": Vault.Entry(cookies: [], updated: saved)])
        let before = try snapshot(spike)
        let data = dir.appendingPathComponent("iSmith", isDirectory: true)
        let configURL = data.appendingPathComponent("config.json")
        let keys = InMemoryKeyStore()

        let vault = Vault(fileURL: data.appendingPathComponent("vault.json"), keyStore: keys)
        XCTAssertTrue(SpikeImport.runIfNeeded(from: spike, configURL: configURL, vault: vault))
        let config = Config(fileURL: configURL, hasSession: { [vault] in vault.hasSession($0) })
        XCTAssertEqual(config.spaces.map(\.id), ["contoso", "fabrikam"], "the spike's spaces, not the starter")
        XCTAssertEqual(config.space("fabrikam")?.bindings, ["microsoft": "ms-fabrikam"])
        XCTAssertEqual(config.shared["google"], "shared-google", "missing shared accounts are filled in as usual")

        let reopened = Vault(fileURL: data.appendingPathComponent("vault.json"), keyStore: keys)
        XCTAssertEqual(reopened.records(for: "shared-google")?.count, 2, "sign-ins come over")
        XCTAssertEqual(reopened.entries["shared-google"]?.updated, saved, "with their dates")
        XCTAssertEqual(reopened.records(for: "ms-fabrikam"), [])
        let onDisk = String(decoding: try Data(contentsOf: data.appendingPathComponent("vault.json")), as: UTF8.self)
        XCTAssertFalse(onDisk.contains("secret-sid-value"), "imported sign-ins are encrypted")
        XCTAssertEqual(try permissions(configURL), 0o600)

        XCTAssertEqual(try snapshot(spike), before, "the spike's files are unchanged")
        XCTAssertFalse(SpikeImport.runIfNeeded(from: spike, configURL: configURL, vault: reopened),
                       "the import runs once: iSmith now has a config")
    }

    func testSpikeImportMigratesAnOlderConfig() throws {
        let spike = try writeSpike(config: """
            {"providers":[],"accounts":[{"id":"google-personal","providerID":"google","name":"personal"}],
             "spaces":[{"id":"a","name":"A","color":0,"storeID":"6F1C2A40-0000-4000-9000-0000000000C1","bindings":{"google":"google-personal"},"home":""}]}
            """, vault: ["google-personal": Vault.Entry(cookies: records(), updated: Date())])
        let data = dir.appendingPathComponent("iSmith", isDirectory: true)
        let configURL = data.appendingPathComponent("config.json")
        let vault = Vault(fileURL: data.appendingPathComponent("vault.json"), keyStore: InMemoryKeyStore())
        XCTAssertTrue(SpikeImport.runIfNeeded(from: spike, configURL: configURL, vault: vault))
        let config = Config(fileURL: configURL, hasSession: { [vault] in vault.hasSession($0) })
        XCTAssertEqual(config.shared["google"], "google-personal", "the signed-in account becomes the shared one")
        XCTAssertEqual(config.space("a")?.bindings, [:])
    }

    func testSpikeImportWaitsForAVaultThatCanSave() throws {
        let spike = try writeSpike(config: #"{"version":2,"providers":[],"accounts":[],"spaces":[]}"#,
                                   vault: ["shared-google": Vault.Entry(cookies: records(), updated: Date())])
        let data = dir.appendingPathComponent("iSmith", isDirectory: true)
        let configURL = data.appendingPathComponent("config.json")
        let locked = Vault(fileURL: data.appendingPathComponent("vault.json"), keyStore: FailingKeyStore())
        XCTAssertFalse(SpikeImport.runIfNeeded(from: spike, configURL: configURL, vault: locked))
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path), "the import isn't marked done")

        let keys = InMemoryKeyStore()
        let vault = Vault(fileURL: data.appendingPathComponent("vault.json"), keyStore: keys)
        XCTAssertTrue(SpikeImport.runIfNeeded(from: spike, configURL: configURL, vault: vault), "a later launch imports")
        XCTAssertEqual(Vault(fileURL: data.appendingPathComponent("vault.json"), keyStore: keys).entries.count, 1)
    }

    func testSpikeImportSkipsWhenISmithHasAConfig() throws {
        let spike = try writeSpike(config: #"{"version":2,"providers":[],"accounts":[],"spaces":[]}"#,
                                   vault: ["shared-google": Vault.Entry(cookies: records(), updated: Date())])
        let data = dir.appendingPathComponent("iSmith", isDirectory: true)
        let configURL = data.appendingPathComponent("config.json")
        let vault = Vault(fileURL: data.appendingPathComponent("vault.json"), keyStore: InMemoryKeyStore())
        _ = Config(fileURL: configURL, hasSession: { _ in false })
        XCTAssertFalse(SpikeImport.runIfNeeded(from: spike, configURL: configURL, vault: vault))
        XCTAssertTrue(vault.entries.isEmpty)
    }

    func testNoSpikeNoImport() throws {
        let data = dir.appendingPathComponent("iSmith", isDirectory: true)
        let vault = Vault(fileURL: data.appendingPathComponent("vault.json"), keyStore: InMemoryKeyStore())
        XCTAssertFalse(SpikeImport.runIfNeeded(from: dir.appendingPathComponent("nothing-here"),
                                               configURL: data.appendingPathComponent("config.json"), vault: vault))
    }
}

/// A Keychain where another launch saves its key first: our save fails, and a re-read finds theirs.
private final class RacingKeyStore: KeyStore {
    struct Duplicate: Error {}
    let theirs: SymmetricKey
    private var saved = false
    init(theirs: SymmetricKey) { self.theirs = theirs }
    func loadKey() throws -> SymmetricKey? { saved ? theirs : nil }
    func saveKey(_ key: SymmetricKey) throws {
        saved = true
        throw Duplicate()
    }
}

/// A Keychain that can't be read, as when it's locked or access was denied.
private struct FailingKeyStore: KeyStore {
    struct Locked: Error {}
    func loadKey() throws -> SymmetricKey? { throw Locked() }
    func saveKey(_ key: SymmetricKey) throws { throw Locked() }
}
