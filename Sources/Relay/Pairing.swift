import Foundation

/// The pairing code the iPhone must prove it knows before any input is accepted.
/// Stored in ~/Library/Application Support/Relay/pairing-code (mode 600).
///
/// The code is the secret behind Relay's encryption (see SecureChannel), so new codes are
/// 12 characters from a 31-symbol alphabet (about 59 bits). Codes from older versions
/// (8 characters) keep working; "New Pairing Code…" in the menu replaces one.
final class Pairing {
    static let length = 12
    private static let alphabet = Array("ABCDEFGHJKMNPQRSTUVWXYZ23456789")
    private static let maxFailures = 5
    private static let lockoutSeconds: TimeInterval = 60

    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Relay/pairing-code")

    private var current: String
    private var failures: [String: (count: Int, lockedUntil: Date)] = [:]
    private let lock = NSLock()

    var code: String { lock.withLock { current } }

    init() {
        if let saved = try? String(contentsOf: Pairing.url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), saved.count >= 8 {
            current = saved
        } else {
            current = Pairing.generate()
            Pairing.save(current)
        }
        // Tighten permissions on codes written by older versions too.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Pairing.url.path)
    }

    /// Replaces the code; every phone has to pair again.
    func reset() {
        let fresh = Pairing.generate()
        lock.withLock { current = fresh; failures = [:] }
        Pairing.save(fresh)
        Log.info("pairing: new pairing code created")
    }

    /// Runs `check` with the code unless `peer` is locked out, and counts failures:
    /// five wrong attempts lock that address out for a minute.
    func authenticate(peer: String, _ check: (String) -> Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        var entry = failures[peer] ?? (0, .distantPast)
        if entry.lockedUntil > now { return false }
        if check(current) {
            failures[peer] = nil
            return true
        }
        entry.count += 1
        if entry.count >= Pairing.maxFailures {
            entry = (0, now.addingTimeInterval(Pairing.lockoutSeconds))
            Log.info("pairing: \(peer) locked out for \(Int(Pairing.lockoutSeconds))s")
        }
        failures[peer] = entry
        // Forget stale entries so many addresses can't grow this without bound.
        if failures.count > 256 { failures = failures.filter { $0.value.lockedUntil > now || $0.value.count > 0 } }
        if failures.count > 1024 { failures.removeAll() }
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

    private static func save(_ code: String) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        // Create with owner-only permissions before writing, so the code is never world-readable.
        fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        try? Data(code.utf8).write(to: url)
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
