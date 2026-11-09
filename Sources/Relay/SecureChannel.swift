import CryptoKit
import Foundation

/// End-to-end encryption between Relay and the phone, authenticated by the pairing code.
///
///   Mac → phone   "n <nonce> <Mac X25519 public key> <PBKDF2 salt> <iterations>"   (plaintext)
///   phone → Mac   "a <nonce> <phone X25519 public key> <proof>"                    (plaintext)
///     stretched = PBKDF2-SHA256(pairing code, salt, iterations)       (cached on both sides)
///     shared    = X25519(own ephemeral secret, other's public key)    (fresh every connection)
///     keys      = HKDF-SHA256(ikm: shared ‖ stretched,
///                             salt: macNonce ‖ phoneNonce ‖ macPublic ‖ phonePublic,
///                             info: "relay v2", 96 bytes) → auth ‖ phone→Mac ‖ Mac→phone
///     proof     = HMAC-SHA256(auth key, "relay-auth-v2")
///   Then every message in both directions is a binary WebSocket frame sealed with
///   ChaCha20-Poly1305 under that direction's key; nonce = 4 zero bytes ‖ 64-bit big-endian
///   message counter, so a replayed, reordered or altered message fails to open and the
///   connection is closed. The first plaintext byte says what follows: "T" text, "F" frame.
///
/// What this gives:
/// - The pairing code never crosses the network.
/// - Someone recording the Wi-Fi sees only ciphertext and can't test guesses for the code
///   offline, because the keys also depend on the X25519 secret they never see.
/// - Recorded sessions stay unreadable even if the code leaks later (forward secrecy).
/// - An attacker who can intercept and alter traffic could try guesses against a captured
///   proof, but each guess costs the full PBKDF2 stretch.
/// Mirrors web/crypto.js; tools/securitytest.swift checks both ends together.
struct SecureChannel {
    static let info = Data("relay v2".utf8)
    static let proofLabel = Data("relay-auth-v2".utf8)

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    static func randomNonce() -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// Checks the phone's proof against the stretched code; returns the channel if it matches.
    static func accept(stretched: Data, macNonce: Data, macSecret: Curve25519.KeyAgreement.PrivateKey,
                       phoneNonce: Data, phonePublic: Data, proof: Data) -> SecureChannel? {
        guard phoneNonce.count == 16, proof.count == 32,
              let phoneKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: phonePublic),
              let shared = try? macSecret.sharedSecretFromKeyAgreement(with: phoneKey) else { return nil }
        let sharedBytes = shared.withUnsafeBytes { Data($0) }
        guard sharedBytes.contains(where: { $0 != 0 }) else { return nil }   // low-order public key
        let macPublic = macSecret.publicKey.rawRepresentation
        let keys = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: sharedBytes + stretched),
                                          salt: macNonce + phoneNonce + macPublic + phonePublic,
                                          info: info, outputByteCount: 96)
        let bytes = keys.withUnsafeBytes { Data($0) }
        let auth = SymmetricKey(data: bytes[0..<32])
        // Constant-time comparison.
        guard HMAC<SHA256>.isValidAuthenticationCode(proof, authenticating: proofLabel, using: auth) else { return nil }
        return SecureChannel(sendKey: SymmetricKey(data: bytes[64..<96]),
                             receiveKey: SymmetricKey(data: bytes[32..<64]))
    }

    private init(sendKey: SymmetricKey, receiveKey: SymmetricKey) {
        self.sendKey = sendKey
        self.receiveKey = receiveKey
    }

    mutating func seal(_ plaintext: Data) -> Data? {
        defer { sendCounter += 1 }
        guard let box = try? ChaChaPoly.seal(plaintext, using: sendKey, nonce: SecureChannel.nonce(sendCounter)) else { return nil }
        return Data(box.ciphertext) + box.tag   // rebased to index 0
    }

    /// nil if the message was altered, replayed or arrived out of order.
    mutating func open(_ sealed: Data) -> Data? {
        guard sealed.count >= 16,
              let box = try? ChaChaPoly.SealedBox(nonce: SecureChannel.nonce(receiveCounter),
                                                  ciphertext: sealed.dropLast(16), tag: sealed.suffix(16)),
              let plaintext = try? ChaChaPoly.open(box, using: receiveKey) else { return nil }
        receiveCounter += 1
        return plaintext
    }

    private static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }
}

extension Data {
    init?(hex: Substring) {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        self = out
    }

    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
