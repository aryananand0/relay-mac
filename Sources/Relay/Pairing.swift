import CommonCrypto
import Foundation

/// The pairing code the iPhone must prove it knows before any input is accepted.
/// Stored in ~/Library/Application Support/Relay/ (owner-only): `pairing-code`, and
/// `pairing-salt` for stretching it.
///
/// - **Strength:** codes are 12 characters from a 31-symbol alphabet (about 59 bits). Shorter
///   codes from older versions are replaced automatically, so those phones pair once more.
/// - **Stretching:** the code is put through PBKDF2-SHA256 (600 000 iterations, per-Mac salt)
///   before it's used. Combined with the X25519 exchange in SecureChannel, a recording of the
///   traffic gives no way to test guesses, and even an attacker in the middle of the network
///   pays 600 000 hashes per guess.
/// - **Guess limits:** five wrong attempts lock an address (IPv6: its /64) out for a minute,
///   and more than 20 wrong attempts a minute from anywhere pause all pairing for a minute.
final class Pairing {
    static let length = 12
    static let iterations: UInt32 = 600_000
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let maxFailures = 5
    private static let lockoutSeconds: TimeInterval = 60
    private static let globalMaxFailures = 20

    private static let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Relay")
    private static let codeURL = dir.appendingPathComponent("pairing-code")
    private static let saltURL = dir.appendingPathComponent("pairing-salt")

    private var current: String
    private var saltBytes: Data
    private var stretchedKey: Data
    private var failures: [String: (count: Int, lockedUntil: Date)] = [:]
    private var recentFailures: [Date] = []
    private var globalLockUntil = Date.distantPast
    private let lock = NSLock()

    var code: String { lock.withLock { current } }
    /// "<salt hex> <iterations>", sent in Relay's challenge so the phone can stretch the code too.
    var stretchParameters: String { lock.withLock { "\(saltBytes.hex) \(Pairing.iterations)" } }

    init() {
        let saved = (try? String(contentsOf: Pairing.codeURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let savedSalt = (try? String(contentsOf: Pairing.saltURL, encoding: .utf8))
            .flatMap { Data(hex: Substring($0.trimmingCharacters(in: .whitespacesAndNewlines))) }
        if let saved, saved.count >= Pairing.length, let savedSalt, savedSalt.count == 16 {
            current = saved
            saltBytes = savedSalt
        } else {
            if saved != nil { Log.info("pairing: replaced an older, shorter pairing code; pair your iPhone again") }
            current = Pairing.generate()
            saltBytes = SecureChannel.randomNonce()
            Pairing.save(current, salt: saltBytes)
        }
        stretchedKey = Pairing.stretch(current, salt: saltBytes)
        for url in [Pairing.codeURL, Pairing.saltURL] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Replaces the code (and salt); every phone has to pair again.
    func reset() {
        let fresh = Pairing.generate(), salt = SecureChannel.randomNonce()
        let key = Pairing.stretch(fresh, salt: salt)
        lock.withLock {
            current = fresh; saltBytes = salt; stretchedKey = key
            failures = [:]; recentFailures = []; globalLockUntil = .distantPast
        }
        Pairing.save(fresh, salt: salt)
        Log.info("pairing: new pairing code created")
    }

    /// Runs `check` with the stretched code unless pairing is locked for `peer` (a lockout key
    /// from PeerPolicy) or globally, and counts failures.
    func authenticate(peer: String, _ check: (Data) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if globalLockUntil > now { return false }
        var entry = failures[peer] ?? (0, .distantPast)
        if entry.lockedUntil > now { return false }
        if check(stretchedKey) {
            failures[peer] = nil
            return true
        }
        entry.count += 1
        if entry.count >= Pairing.maxFailures {
            entry = (0, now.addingTimeInterval(Pairing.lockoutSeconds))
            Log.info("pairing: \(peer) locked out for \(Int(Pairing.lockoutSeconds))s")
        }
        failures[peer] = entry
        // A cap across all addresses, so changing address doesn't buy more guesses.
        recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 60 } + [now]
        if recentFailures.count > Pairing.globalMaxFailures {
            globalLockUntil = now.addingTimeInterval(Pairing.lockoutSeconds)
            recentFailures = []
            Log.info("pairing: too many wrong attempts; pairing paused for \(Int(Pairing.lockoutSeconds))s")
        }
        // Bound memory without ever forgetting an address that's locked out.
        if failures.count > 1024 { failures = failures.filter { $0.value.lockedUntil > now } }
        return false
    }

    /// "ABCD EFGH JKMN" for display.
    static func spaced(_ code: String) -> String {
        stride(from: 0, to: code.count, by: 4).map { i in
            let start = code.index(code.startIndex, offsetBy: i)
            return String(code[start..<(code.index(start, offsetBy: 4, limitedBy: code.endIndex) ?? code.endIndex)])
        }.joined(separator: " ")
    }

    private static func generate() -> String {
        var rng = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
    }

    /// PBKDF2-HMAC-SHA256, 32 bytes. Matches RelayCrypto.stretchCode in web/crypto.js.
    static func stretch(_ code: String, salt: Data) -> Data {
        var out = Data(count: 32)
        let password = Array(code.utf8)
        let status = out.withUnsafeMutableBytes { outPtr in
            salt.withUnsafeBytes { saltPtr in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     password.map { CChar(bitPattern: $0) }, password.count,
                                     saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), iterations,
                                     outPtr.bindMemory(to: UInt8.self).baseAddress, 32)
            }
        }
        precondition(status == kCCSuccess, "PBKDF2 failed")
        return out
    }

    private static func save(_ code: String, salt: Data) {
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for (url, text) in [(codeURL, code), (saltURL, salt.hex)] {
            // Create with owner-only permissions before writing, so it's never world-readable.
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try? Data(text.utf8).write(to: url)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}
