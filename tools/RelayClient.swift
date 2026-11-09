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
        guard case .string(let hello) = try await task.receive(), hello.hasPrefix("n "),
              let macNonce = Self.bytes(hex: String(hello.dropFirst(2))) else { throw URLError(.badServerResponse) }
        let phoneNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        let keys = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)),
                                          salt: macNonce + phoneNonce, info: Data("relay v1".utf8), outputByteCount: 96)
        let k = keys.withUnsafeBytes { Data($0) }
        let proof = Data(HMAC<SHA256>.authenticationCode(for: Data("relay-auth-v1".utf8), using: SymmetricKey(data: k[0..<32])))
        lock.withLock {
            sendKey = SymmetricKey(data: k[32..<64])
            receiveKey = SymmetricKey(data: k[64..<96])
        }
        try await task.send(.string("a \(Self.hex(phoneNonce)) \(Self.hex(proof))"))
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
