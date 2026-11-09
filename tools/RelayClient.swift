import CommonCrypto
import CryptoKit
import Foundation

/// Test-tool client for Relay's encrypted protocol (see Sources/Relay/SecureChannel.swift).
/// It mirrors the URLSessionWebSocketTask calls the tools use: send(.string(…)),
/// receive(), cancel(with:reason:). Sending "a <code>" performs the pairing handshake, so the
/// pairing code is never sent; afterwards every message is sealed with ChaCha20-Poly1305.
final class RelayClient: @unchecked Sendable {
    enum Message { case string(String), data(Data) }
    enum CloseCode { case normalClosure }

    private let task: URLSessionWebSocketTask
    private let lock = NSLock()
    private var sendKey: SymmetricKey?
    private var receiveKey: SymmetricKey?
    private var sendCounter: UInt64 = 0
    private var receiveCounter: UInt64 = 0

    init(url: String = "ws://127.0.0.1:8766/") {
        task = URLSession.shared.webSocketTask(with: URL(string: url)!)
        task.resume()
    }

    func resume() {}

    func send(_ message: Message) async throws {
        guard case .string(let text) = message else { return }
        if text.hasPrefix("a "), sendKey == nil { return try await pair(code: String(text.dropFirst(2))) }
        let sealed: Data? = lock.withLock {
            guard let key = sendKey else { return nil }
            defer { sendCounter += 1 }
            let box = try? ChaChaPoly.seal(Data("T".utf8) + Data(text.utf8), using: key, nonce: Self.nonce(sendCounter))
            return box.map { Data($0.ciphertext) + $0.tag }
        }
        guard let sealed else { throw URLError(.userAuthenticationRequired) }
        try await task.send(.data(sealed))
    }

    /// Plaintext before pairing ("no", "paused"); decrypted text or preview frames after.
    func receive() async throws -> Message {
        switch try await task.receive() {
        case .string(let s): return .string(s)
        case .data(let d):
            let plain: Data? = lock.withLock {
                guard let key = receiveKey, d.count >= 16,
                      let box = try? ChaChaPoly.SealedBox(nonce: Self.nonce(receiveCounter),
                                                          ciphertext: d.dropLast(16), tag: d.suffix(16)),
                      let p = try? ChaChaPoly.open(box, using: key) else { return nil }
                receiveCounter += 1
                return p
            }
            guard let plain, let kind = plain.first else { throw URLError(.cannotDecodeContentData) }
            return kind == UInt8(ascii: "F") ? .data(Data(plain.dropFirst()))
                                             : .string(String(decoding: plain.dropFirst(), as: UTF8.self))
        @unknown default: throw URLError(.cannotDecodeContentData)
        }
    }

    func cancel(with: CloseCode, reason: Data?) { task.cancel(with: .normalClosure, reason: nil) }

    private func pair(code: String) async throws {
        guard case .string(let hello) = try await task.receive() else { throw URLError(.badServerResponse) }
        guard let reply = Self.answer(hello: hello, code: code) else { throw URLError(.badServerResponse) }
        lock.withLock { sendKey = reply.sendKey; receiveKey = reply.receiveKey }
        try await task.send(.string(reply.text))
    }

    /// Answers "n <nonce> <public key> <salt> <iterations>"; see SecureChannel.swift.
    static func answer(hello: String, code: String, proofLabel: String = "relay-auth-v2")
        -> (text: String, sendKey: SymmetricKey, receiveKey: SymmetricKey)? {
        let p = hello.split(separator: " ")
        guard p.count == 5, p[0] == "n", let macNonce = bytes(hex: String(p[1])), let macPublicRaw = bytes(hex: String(p[2])),
              let salt = bytes(hex: String(p[3])), let iterations = UInt32(p[4]),
              let macPublic = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: macPublicRaw) else { return nil }
        let secret = Curve25519.KeyAgreement.PrivateKey()
        guard let shared = try? secret.sharedSecretFromKeyAgreement(with: macPublic) else { return nil }
        let phoneNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let phonePublic = secret.publicKey.rawRepresentation
        let ikm = shared.withUnsafeBytes { Data($0) } + stretch(code, salt: salt, iterations: iterations)
        let k = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ikm),
                                       salt: macNonce + phoneNonce + macPublicRaw + phonePublic,
                                       info: Data("relay v2".utf8), outputByteCount: 96).withUnsafeBytes { Data($0) }
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data(proofLabel.utf8), using: SymmetricKey(data: k[0..<32])))
        return ("a \(hex(phoneNonce)) \(hex(phonePublic)) \(hex(proof))",
                SymmetricKey(data: k[32..<64]), SymmetricKey(data: k[64..<96]))
    }

    private static var stretchCache: [String: Data] = [:]
    static func stretch(_ code: String, salt: Data, iterations: UInt32) -> Data {
        let id = "\(code)|\(hex(salt))|\(iterations)"
        if let cached = stretchCache[id] { return cached }
        var out = Data(count: 32)
        let pw = Array(code.utf8).map { CChar(bitPattern: $0) }
        _ = out.withUnsafeMutableBytes { o in salt.withUnsafeBytes { s in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw, pw.count, s.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                 CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations, o.bindMemory(to: UInt8.self).baseAddress, 32)
        } }
        stretchCache[id] = out
        return out
    }

    static func nonce(_ counter: UInt64) -> ChaChaPoly.Nonce {
        var bytes = Data(count: 4)
        withUnsafeBytes(of: counter.bigEndian) { bytes.append(contentsOf: $0) }
        return try! ChaChaPoly.Nonce(data: bytes)
    }

    static func hex(_ d: Data) -> String { d.map { String(format: "%02x", $0) }.joined() }

    static func bytes(hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            out.append(b)
            i = j
        }
        return out
    }
}
