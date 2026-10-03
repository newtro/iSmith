import CryptoKit
import Foundation

/// Field encryption for the password store: each username and password is its own AES-GCM sealed
/// box (nonce, ciphertext and tag), with the row's id, origin and field name as authenticated
/// data. A ciphertext moved to another row, another field, or a row whose origin was edited in
/// the file no longer opens, so tampering with the database can't make a bank password autofill
/// on another site.
enum LoginCrypto {
    enum Field: String {
        case username, password
    }

    static let version = "v1"

    static func associatedData(id: UUID, origin: Origin, field: Field) -> Data {
        Data("ismith-passwords|\(version)|\(id.uuidString.lowercased())|\(origin.serialized)|\(field.rawValue)".utf8)
    }

    static func seal(_ value: String, id: UUID, origin: Origin, field: Field, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(Data(value.utf8), using: key,
                                   authenticating: associatedData(id: id, origin: origin, field: field))
        guard let combined = box.combined else { throw PasswordStoreError.encryptionFailed }
        return combined
    }

    static func open(_ combined: Data, id: UUID, origin: Origin, field: Field, key: SymmetricKey) throws -> String {
        let box = try AES.GCM.SealedBox(combined: combined)
        let plain = try AES.GCM.open(box, using: key, authenticating: associatedData(id: id, origin: origin, field: field))
        guard let text = String(data: plain, encoding: .utf8) else { throw PasswordStoreError.unreadableRow }
        return text
    }

    /// A known value sealed with the store's key, saved in the database so opening it with the
    /// wrong key is caught at once rather than as every row failing.
    static let keyCheckPlaintext = Data("ismith-passwords-key-check".utf8)

    static func sealKeyCheck(_ key: SymmetricKey) throws -> Data {
        guard let combined = try AES.GCM.seal(keyCheckPlaintext, using: key).combined else {
            throw PasswordStoreError.encryptionFailed
        }
        return combined
    }

    static func verifyKeyCheck(_ combined: Data, key: SymmetricKey) -> Bool {
        guard let box = try? AES.GCM.SealedBox(combined: combined),
              let plain = try? AES.GCM.open(box, using: key) else { return false }
        return plain == keyCheckPlaintext
    }
}
