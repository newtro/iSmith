import Foundation
import Security

/// Where the agent keeps its Mac key pair and its relay bearer token.
public protocol SecretStore: AnyObject {
    /// nil when nothing is saved under `name`. Throws when the store can't be read.
    func load(_ name: String) throws -> Data?
    /// Saves (replacing any earlier value).
    func save(_ data: Data, as name: String) throws
    func delete(_ name: String) throws
}

/// Generic passwords in the file-based login Keychain, created by the agent, so their access list
/// trusts the agent's signature and no other app (iSmith itself never reads them). Never synced.
public final class KeychainSecretStore: SecretStore {
    /// The agent's bundle id: items are `<prefix>.mac-key` and `<prefix>.mac-token`.
    public let servicePrefix: String
    public let labelPrefix: String

    public init(servicePrefix: String, labelPrefix: String) {
        self.servicePrefix = servicePrefix
        self.labelPrefix = labelPrefix
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: OSStatus
        public var description: String {
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }

    private func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(servicePrefix).\(name)",
         kSecAttrAccount as String: "2fasync",
         kSecUseDataProtectionKeychain as String: false]
    }

    public func load(_ name: String) throws -> Data? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data = out as? Data else { throw Failure(status: errSecDecode) }
        return data
    }

    /// Always a new item: whatever is under the name is deleted first (fails if it can't be),
    /// then the item is added. An item added by the agent without an explicit access object gets
    /// the file Keychain's default access list, which trusts only the creating app, so an item
    /// someone else created beforehand (with an "any app" list) is never written into.
    public func save(_ data: Data, as name: String) throws {
        try delete(name)
        var add = query(name)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = "\(labelPrefix) \(name)"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    public func delete(_ name: String) throws {
        let status = SecItemDelete(query(name) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }
}

/// Secrets in memory, for tests.
public final class InMemorySecretStore: SecretStore {
    public var values: [String: Data] = [:]
    public init() {}
    public func load(_ name: String) throws -> Data? { values[name] }
    public func save(_ data: Data, as name: String) throws { values[name] = data }
    public func delete(_ name: String) throws { values[name] = nil }
}
