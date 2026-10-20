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

    public func save(_ data: Data, as name: String) throws {
        let update = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure(status: update) }
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
