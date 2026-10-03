import CommonCrypto
import Foundation
import Security

/// Where the "Brave Safe Storage" password comes from. The app uses `KeychainSafeStorage`; tests
/// pass a fixed password so they never touch the real Keychain.
public protocol SafeStoragePasswordSource {
    /// The password bytes exactly as stored (Brave keeps a base64 string; it is used as-is).
    func safeStoragePassword() throws -> Data
}

public enum SafeStorageError: Error, Equatable {
    /// No "Brave Safe Storage" item: Brave was never run, or never saved a password.
    case notFound
    /// The user clicked "Deny" (or cancelled) on macOS's prompt.
    case denied
    /// Any other Keychain failure, with its status.
    case keychain(OSStatus, String)
}

/// Reads the password from the login Keychain (service "Brave Safe Storage", account "Brave").
///
/// The item belongs to Brave, so macOS shows its own prompt asking for the user's Mac password
/// before handing it over ("Always Allow" stops it asking again). That prompt is the user's
/// decision and is never answered or worked around here.
public struct KeychainSafeStorage: SafeStoragePasswordSource {
    public static let service = "Brave Safe Storage"
    public static let account = "Brave"

    public var service: String
    public var account: String

    public init(service: String = KeychainSafeStorage.service, account: String = KeychainSafeStorage.account) {
        self.service = service
        self.account = account
    }

    public func safeStoragePassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            // Brave's item is in the file-based login Keychain.
            kSecUseDataProtectionKeychain as String: false,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, !data.isEmpty else { throw SafeStorageError.notFound }
            return data
        case errSecItemNotFound:
            throw SafeStorageError.notFound
        case errSecUserCanceled, errSecAuthFailed:
            throw SafeStorageError.denied
        default:
            throw SafeStorageError.keychain(status, SecCopyErrorMessageString(status, nil) as String? ?? "unknown")
        }
    }
}

public enum PasswordDecryptionError: Error, Equatable {
    /// The value has a version prefix this reader doesn't know (macOS Brave only writes `v10`).
    case unsupportedVersion(String)
    /// The ciphertext didn't decrypt: wrong key, or damaged data.
    case decryptFailed
    /// It decrypted, but not to UTF-8 text.
    case notText
}

/// Chromium's macOS password encryption ("OSCrypt"): `v10` + AES-128-CBC(PKCS7) with a key of
/// PBKDF2-HMAC-SHA1(safe storage password, "saltysalt", 1003 rounds, 16 bytes) and an IV of 16
/// spaces.
public struct ChromiumPasswordCipher {
    public static let salt = Data("saltysalt".utf8)
    public static let iterations: UInt32 = 1003
    public static let keyLength = kCCKeySizeAES128
    public static let iv = Data(repeating: 0x20, count: kCCBlockSizeAES128)
    public static let v10Prefix = Data("v10".utf8)

    public let key: Data

    public init(key: Data) {
        self.key = key
    }

    public init(safeStoragePassword: Data) throws {
        key = try Self.deriveKey(password: safeStoragePassword)
    }

    public static func deriveKey(password: Data) throws -> Data {
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                         passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                                         password.count,
                                         saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         salt.count,
                                         CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                                         iterations,
                                         keyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                                         keyLength)
                }
            }
        }
        guard status == kCCSuccess else { throw PasswordDecryptionError.decryptFailed }
        return key
    }

    /// Whether a stored value is encrypted (`v10…`), as opposed to empty or legacy plain text.
    public static func isEncrypted(_ value: Data) -> Bool {
        value.starts(with: v10Prefix)
    }

    /// Decrypts a `password_value` column. An empty value is an empty password. A value with no
    /// version prefix is legacy plain text, which Chromium also returns as-is.
    public func decrypt(_ value: Data) throws -> String {
        guard Self.isEncrypted(value) else { return try Self.decodeUnencrypted(value) }
        let plain = try Self.crypt(CCOperation(kCCDecrypt), value.dropFirst(Self.v10Prefix.count), key: key)
        guard let text = String(data: plain, encoding: .utf8) else { throw PasswordDecryptionError.notText }
        return text
    }

    /// A value without the `v10` prefix: empty, or legacy plain text. A different version prefix
    /// (`v11`, from another platform) is refused rather than imported as garbage.
    public static func decodeUnencrypted(_ value: Data) throws -> String {
        if value.isEmpty { return "" }
        if value.count >= 3, value.first == UInt8(ascii: "v"),
           value.dropFirst().prefix(2).allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }) {
            throw PasswordDecryptionError.unsupportedVersion(String(decoding: value.prefix(3), as: UTF8.self))
        }
        guard let text = String(data: value, encoding: .utf8) else { throw PasswordDecryptionError.notText }
        return text
    }

    /// Encrypts as Chromium does, `v10` prefix included. Used by tests to build fixtures.
    public func encrypt(_ text: String) throws -> Data {
        Self.v10Prefix + (try Self.crypt(CCOperation(kCCEncrypt), Data(text.utf8), key: key))
    }

    private static func crypt(_ op: CCOperation, _ input: Data, key: Data) throws -> Data {
        guard key.count == keyLength else { throw PasswordDecryptionError.decryptFailed }
        if op == CCOperation(kCCDecrypt), input.isEmpty || input.count % kCCBlockSizeAES128 != 0 {
            throw PasswordDecryptionError.decryptFailed
        }
        let input = Data(input) // rebase a slice to index 0
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    iv.withUnsafeBytes { v in
                        CCCrypt(op, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                k.baseAddress, key.count, v.baseAddress,
                                inp.baseAddress, input.count,
                                out.baseAddress, outputCapacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw PasswordDecryptionError.decryptFailed }
        output.count = moved
        return output
    }
}
