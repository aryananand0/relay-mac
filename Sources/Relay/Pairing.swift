import Foundation

/// The pairing code the iPhone must present before any input is accepted.
/// Stored in ~/Library/Application Support/Relay/pairing-code (mode 600).
final class Pairing {
    let code: String

    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let maxFailures = 5
    private static let lockoutSeconds: TimeInterval = 60

    private var failures: [String: (count: Int, lockedUntil: Date)] = [:]
    private let lock = NSLock()

    init() {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Relay")
        let url = dir.appendingPathComponent("pairing-code")
        if let saved = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 8 {
            code = saved
        } else {
            var rng = SystemRandomNumberGenerator()
            code = String((0..<8).map { _ in Pairing.alphabet.randomElement(using: &rng)! })
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? code.write(to: url, atomically: true, encoding: .utf8)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Checks a candidate code from `peer`, locking the peer out after repeated failures.
    func verify(_ candidate: String, peer: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        var entry = failures[peer] ?? (0, .distantPast)
        if entry.lockedUntil > Date() { return false }

        let normalized = candidate.uppercased().filter { $0 != "-" && $0 != " " }
        if Pairing.constantTimeEqual(normalized, code) {
            failures[peer] = nil
            return true
        }
        entry.count += 1
        if entry.count >= Pairing.maxFailures {
            entry = (0, Date().addingTimeInterval(Pairing.lockoutSeconds))
            Log.info("pairing: \(peer) locked out for \(Int(Pairing.lockoutSeconds))s")
        }
        failures[peer] = entry
        return false
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
