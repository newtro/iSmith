import BraveImport
import XCTest

/// The v10 scheme, checked against vectors computed outside Swift.
final class CipherTests: XCTestCase {
    /// `hashlib.pbkdf2_hmac('sha1', b'test-safe-storage-password', b'saltysalt', 1003, 16)`.
    private let knownKeyHex = "8d980c26091f4ec99749af7dd4090b2e"
    /// `printf 'hunter2-ünïcode' | openssl enc -aes-128-cbc -K <key> -iv 2020…20`.
    private let knownCiphertextHex = "603918a10d93c56e7e787d2e45266ec7f5606214d40b80d9515aca4b48faa416"

    func testKeyDerivationMatchesPythonVector() throws {
        let key = try ChromiumPasswordCipher.deriveKey(password: Data("test-safe-storage-password".utf8))
        XCTAssertEqual(hex(key), knownKeyHex)
    }

    func testDecryptsOpenSSLVector() throws {
        let cipher = try ChromiumPasswordCipher(safeStoragePassword: Data("test-safe-storage-password".utf8))
        let value = Data("v10".utf8) + data(hex: knownCiphertextHex)
        XCTAssertEqual(try cipher.decrypt(value), "hunter2-ünïcode")
    }

    func testDecryptsIndependentFixtureEncryption() throws {
        let cipher = try ChromiumPasswordCipher(safeStoragePassword: Data("test-safe-storage-password".utf8))
        for text in ["a", "exactly16bytes!!", "pässwörd 🔐 密码", String(repeating: "x", count: 200)] {
            XCTAssertEqual(try cipher.decrypt(braveEncrypt(text)), text)
            XCTAssertEqual(try cipher.decrypt(cipher.encrypt(text)), text)
        }
    }

    func testWrongKeyFails() throws {
        let wrong = try ChromiumPasswordCipher(safeStoragePassword: Data("another-password".utf8))
        XCTAssertThrowsError(try wrong.decrypt(braveEncrypt("hunter2-hunter2-hunter2")))
    }

    func testEmptyLegacyAndOtherVersions() throws {
        let cipher = ChromiumPasswordCipher(key: Data(repeating: 1, count: 16))
        XCTAssertEqual(try cipher.decrypt(Data()), "")
        XCTAssertEqual(try cipher.decrypt(Data("plain-legacy".utf8)), "plain-legacy")
        XCTAssertThrowsError(try cipher.decrypt(Data("v11abcdefabcdefabcdef".utf8))) { error in
            XCTAssertEqual(error as? PasswordDecryptionError, .unsupportedVersion("v11"))
        }
        // A truncated or misaligned ciphertext is refused, not crashed on.
        XCTAssertThrowsError(try cipher.decrypt(Data("v10".utf8)))
        XCTAssertThrowsError(try cipher.decrypt(Data("v10".utf8) + Data(repeating: 7, count: 15)))
    }

    private func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    private func data(hex: String) -> Data {
        var bytes = [UInt8]()
        var chars = hex.makeIterator()
        while let a = chars.next(), let b = chars.next() { bytes.append(UInt8(String([a, b]), radix: 16)!) }
        return Data(bytes)
    }
}
