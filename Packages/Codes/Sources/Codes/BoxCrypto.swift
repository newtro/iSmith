import Clibsodium
import CryptoKit
import Foundation

/// An X25519 key pair for libsodium's `crypto_box`.
public struct BoxKeyPair: Equatable, Sendable {
    public let publicKey: Data
    public let secretKey: Data

    /// A fresh key pair (`crypto_box_keypair`).
    public static func generate() -> BoxKeyPair {
        BoxCrypto.ready()
        var pk = [UInt8](repeating: 0, count: BoxCrypto.keyBytes)
        var sk = [UInt8](repeating: 0, count: BoxCrypto.keyBytes)
        _ = crypto_box_keypair(&pk, &sk)
        return BoxKeyPair(publicKey: Data(pk), secretKey: Data(sk))
    }

    /// The key pair `crypto_box_seed_keypair` derives from a 32-byte seed (the test vectors).
    public static func fromSeed(_ seed: Data) -> BoxKeyPair? {
        guard seed.count == BoxCrypto.keyBytes else { return nil }
        BoxCrypto.ready()
        var pk = [UInt8](repeating: 0, count: BoxCrypto.keyBytes)
        var sk = [UInt8](repeating: 0, count: BoxCrypto.keyBytes)
        let rc = seed.withUnsafeBytes { crypto_box_seed_keypair(&pk, &sk, $0.bindMemory(to: UInt8.self).baseAddress!) }
        return rc == 0 ? BoxKeyPair(publicKey: Data(pk), secretKey: Data(sk)) : nil
    }

    /// Rebuilds the pair from the secret key (the public key is `crypto_scalarmult_base` of it).
    public init?(secretKey: Data) {
        guard secretKey.count == BoxCrypto.keyBytes else { return nil }
        BoxCrypto.ready()
        var pk = [UInt8](repeating: 0, count: BoxCrypto.keyBytes)
        let sk = [UInt8](secretKey)
        guard crypto_scalarmult_base(&pk, sk) == 0 else { return nil }
        self.init(publicKey: Data(pk), secretKey: secretKey)
    }

    public init(publicKey: Data, secretKey: Data) {
        self.publicKey = publicKey
        self.secretKey = secretKey
    }
}

/// The v1 constructions: `crypto_box` sealing, the pairing proof and the fingerprint.
public enum BoxCrypto {
    public static let keyBytes = 32
    public static let nonceBytes = 24
    static let macBytes = 16

    private static let initialized: Bool = sodium_init() >= 0
    static func ready() { precondition(initialized, "libsodium failed to initialize") }

    /// `crypto_box_open_easy(ct, nonce, senderPub, recipientSecret)`. nil when the box doesn't
    /// open (wrong key, altered ciphertext, bad sizes).
    public static func open(ciphertext: Data, nonce: Data, senderPublicKey: Data, recipientSecretKey: Data) -> Data? {
        guard nonce.count == nonceBytes, senderPublicKey.count == keyBytes, recipientSecretKey.count == keyBytes,
              ciphertext.count >= macBytes else { return nil }
        ready()
        var out = [UInt8](repeating: 0, count: ciphertext.count - macBytes)
        let c = [UInt8](ciphertext), n = [UInt8](nonce), pk = [UInt8](senderPublicKey), sk = [UInt8](recipientSecretKey)
        let rc = crypto_box_open_easy(&out, c, UInt64(c.count), n, pk, sk)
        return rc == 0 ? Data(out) : nil
    }

    /// `crypto_box_easy(plaintext, nonce, recipientPub, senderSecret)`; the phone's side, used by
    /// the tests and the fake relay's phone.
    public static func seal(_ plaintext: Data, nonce: Data, recipientPublicKey: Data, senderSecretKey: Data) -> Data? {
        guard nonce.count == nonceBytes, recipientPublicKey.count == keyBytes, senderSecretKey.count == keyBytes else { return nil }
        ready()
        var out = [UInt8](repeating: 0, count: plaintext.count + macBytes)
        let m = [UInt8](plaintext), n = [UInt8](nonce), pk = [UInt8](recipientPublicKey), sk = [UInt8](senderSecretKey)
        let rc = crypto_box_easy(&out, m, UInt64(m.count), n, pk, sk)
        return rc == 0 ? Data(out) : nil
    }

    /// Cryptographically random bytes (`randombytes_buf`).
    public static func randomBytes(_ count: Int) -> Data {
        ready()
        var out = [UInt8](repeating: 0, count: count)
        randombytes_buf(&out, count)
        return Data(out)
    }

    /// `HMAC-SHA256(key = S, msg = "2fasync-pair-v1" || pairingId (36 ASCII) || macPub || phonePub)`.
    public static func pairingProof(secret: Data, pairingID: String, macPublicKey: Data, phonePublicKey: Data) -> Data {
        var msg = Data("2fasync-pair-v1".utf8)
        msg.append(Data(pairingID.utf8))
        msg.append(macPublicKey)
        msg.append(phonePublicKey)
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: secret)))
    }

    /// Constant-time check of a proof the relay passed on.
    public static func proofMatches(_ proof: Data, secret: Data, pairingID: String, macPublicKey: Data, phonePublicKey: Data) -> Bool {
        var msg = Data("2fasync-pair-v1".utf8)
        msg.append(Data(pairingID.utf8))
        msg.append(macPublicKey)
        msg.append(phonePublicKey)
        return HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: msg, using: SymmetricKey(data: secret))
    }

    /// `h = SHA-256("2fasync-fp-v1" || macPub || phonePub)`; big-endian uint32 of h[0..4] mod
    /// 1 000 000, as 6 digits with leading zeros.
    public static func fingerprint(macPublicKey: Data, phonePublicKey: Data) -> String {
        var msg = Data("2fasync-fp-v1".utf8)
        msg.append(macPublicKey)
        msg.append(phonePublicKey)
        let h = Array(SHA256.hash(data: msg))
        let n = (UInt32(h[0]) << 24) | (UInt32(h[1]) << 16) | (UInt32(h[2]) << 8) | UInt32(h[3])
        return String(format: "%06u", n % 1_000_000)
    }
}
