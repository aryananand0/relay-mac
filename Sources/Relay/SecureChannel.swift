import CryptoKit
import Foundation

/// End-to-end encryption between Relay and the phone, keyed by the pairing code.
///
///   Mac → phone   "n <16-byte nonce, hex>"                 (plaintext, on connect)
///   phone → Mac   "a <16-byte nonce, hex> <proof, hex>"    (plaintext)
///     keys  = HKDF-SHA256(ikm: pairing code, salt: macNonce ‖ phoneNonce, info: "relay v1", 96 bytes)
///             → auth key ‖ phone→Mac key ‖ Mac→phone key
///     proof = HMAC-SHA256(auth key, "relay-auth-v1")
///   Then every message in both directions is a binary WebSocket frame sealed with
///   ChaCha20-Poly1305 under that direction's key; nonce = 4 zero bytes ‖ 64-bit big-endian
///   message counter, so a replayed, reordered or altered message fails to open and the
///   connection is closed. The first plaintext byte says what follows: "T" text, "F" frame.
///
/// The pairing code never crosses the network, and someone else on the Wi-Fi sees only
/// ciphertext. Mirrors web/crypto.js; tools/securitytest.swift checks both ends together.
struct SecureChannel {
    static let info = Data("relay v1".utf8)
    static let proofLabel = Data("relay-auth-v1".utf8)

    private let sendKey: SymmetricKey
    private let receiveKey: SymmetricKey
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    static func randomNonce() -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &rng) })
    }

    /// Checks the phone's proof for `code`; returns the channel if it matches.
    static func accept(code: String, macNonce: Data, phoneNonce: Data, proof: Data) -> SecureChannel? {
        guard phoneNonce.count == 16, proof.count == 32 else { return nil }
        let keys = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                                          salt: macNonce + phoneNonce, info: info, outputByteCount: 96)
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
