import CryptoKit
import Foundation
// Security regression checks against the running Relay (run via tools/test.sh).
// Uses at most two wrong pairing attempts, then a correct one, so it never triggers the
// 60-second lockout for this Mac.
setvbuf(stdout, nil, _IONBF, 0)
let code = CommandLine.arguments[1]
var failures = 0
func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL"): \(what)"); if !ok { failures += 1 } }

func raw(origin: String? = nil) -> URLSessionWebSocketTask {
    var request = URLRequest(url: URL(string: "wss://127.0.0.1:8766/")!)
    if let origin { request.setValue(origin, forHTTPHeaderField: "Origin") }
    let t = RelayTrust.session.webSocketTask(with: request)
    t.resume()
    return t
}
func text(_ t: URLSessionWebSocketTask) async -> String? {
    guard case .string(let s)? = try? await t.receive() else { return nil }
    return s
}
/// True if the connection is closed within `seconds` (receive fails).
func closes(_ t: URLSessionWebSocketTask, within seconds: Double) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
        group.addTask { (try? await t.receive()) == nil }
        group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)); return false }
        let first = await group.next()!
        group.cancelAll()
        return first
    }
}
func curl(_ args: [String]) -> String {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["-s", "-i", "--max-time", "3"] + args
    p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}

// 1. The old plaintext login no longer works, and the code isn't what's expected on the wire.
do {
    let t = raw()
    let hello = await text(t)
    let fields = hello?.split(separator: " ") ?? []
    check(fields.count == 5 && fields[1].count == 32 && fields[2].count == 64 && fields[3].count == 32
          && (Int(fields[4]) ?? 0) >= 600_000,
          "Relay opens with a nonce, a fresh X25519 key and PBKDF2 parameters (≥ 600 000 rounds)")
    try await t.send(.string("a \(code)"))
    check(await text(t) == "no", "sending the pairing code in plaintext is rejected")
    t.cancel(with: .normalClosure, reason: nil)
}
// 2. A well-formed answer computed with the wrong code is rejected.
do {
    let t = raw()
    let hello = await text(t) ?? ""
    let wrongCode = String(code.reversed()) == code ? code + "X" : String(code.reversed())
    try await t.send(.string(RelayClient.answer(hello: hello, code: wrongCode)?.text ?? "a 00 00 00"))
    check(await text(t) == "no", "a proof made with the wrong code is rejected")
    t.cancel(with: .normalClosure, reason: nil)
}
// 2b. A replayed handshake from another connection is rejected (fresh keys every time).
do {
    let first = raw()
    let hello1 = await text(first) ?? ""
    let answer = RelayClient.answer(hello: hello1, code: code)!.text
    first.cancel(with: .normalClosure, reason: nil)
    let second = raw()
    _ = await text(second)
    try await second.send(.string(answer))
    check(await text(second) == "no", "a handshake replayed onto a new connection is rejected")
    second.cancel(with: .normalClosure, reason: nil)
}
// 3. The real handshake works (and resets the failure count).
let client = RelayClient()
try await client.send(.string("a \(code)"))
if case .string(let reply) = try await client.receive() { check(reply == "ok", "encrypted pairing succeeds") }
try await client.send(.string("p 7"))
if case .string(let pong) = try await client.receive() { check(pong.hasPrefix("P 7 "), "encrypted commands and replies work") }

// 4. After pairing: plaintext, replayed and altered messages end the connection.
func pairedRaw() async throws -> (URLSessionWebSocketTask, SymmetricKey) {
    let t = raw()
    guard let hello = await text(t), let reply = RelayClient.answer(hello: hello, code: code) else { throw URLError(.badServerResponse) }
    try await t.send(.string(reply.text))
    _ = try await t.receive()   // encrypted "ok"
    return (t, reply.sendKey)
}
func sealed(_ text: String, _ key: SymmetricKey, _ counter: UInt64) -> Data {
    let box = try! ChaChaPoly.seal(Data("T".utf8) + Data(text.utf8), using: key, nonce: RelayClient.nonce(counter))
    return Data(box.ciphertext) + box.tag   // Data(...) rebases the slice to index 0
}
do {
    let (t, _) = try await pairedRaw()
    try await t.send(.string("p 1"))
    check(await closes(t, within: 2), "a plaintext command after pairing is refused")
}
do {
    let (t, key) = try await pairedRaw()
    let message = sealed("p 1", key, 0)
    try await t.send(.data(message))
    _ = try await t.receive()   // the pong
    try await t.send(.data(message))
    check(await closes(t, within: 2), "a replayed message is refused")
}
do {
    let (t, key) = try await pairedRaw()
    var message = sealed("p 1", key, 0)
    message[3] ^= 0x01
    try await t.send(.data(message))
    check(await closes(t, within: 2), "an altered message is refused")
}

// 5. Connections that never pair are closed.
do {
    let t = raw()
    _ = await text(t)
    check(await closes(t, within: 12), "an unpaired connection is closed after 10 s")
}

// 6. Other websites can't open the control connection.
do {
    let t = raw(origin: "http://evil.example")
    check(await text(t) == nil, "a WebSocket from another website's origin is refused")
}

// 7. The web servers: HTTPS for the app, plain HTTP only for setup.
let ca = RelayTrust.caURL.deletingLastPathComponent().appendingPathComponent("relay-ca.pem").path
let index = curl(["--cacert", ca, "https://localhost:8443/"])
check(index.hasPrefix("HTTP/1.1 200") && index.contains("Content-Security-Policy: default-src 'none'")
      && index.contains("connect-src wss://"), "the phone page is served over HTTPS with a strict Content-Security-Policy")
check(index.contains("X-Frame-Options: DENY") && index.contains("X-Content-Type-Options: nosniff"), "anti-framing and nosniff headers")
check(!curl(["https://localhost:8443/"]).hasPrefix("HTTP"), "HTTPS is refused by a client that doesn't trust Relay's CA")
for path in ["/../Package.swift", "/%2e%2e/Package.swift", "/web/../../Package.swift", "//etc/passwd"] {
    check(curl(["--cacert", ca, "--path-as-is", "https://localhost:8443\(path)"]).hasPrefix("HTTP/1.1 404"), "path traversal blocked: \(path)")
}
let setup = curl(["http://127.0.0.1:8765/"])
check(setup.hasPrefix("HTTP/1.1 200") && setup.contains("Set up Relay"), "plain HTTP shows only the setup page")
check(["/relay.js", "/crypto.js", "/relay.css"].allSatisfy { curl(["http://127.0.0.1:8765\($0)"]).hasPrefix("HTTP/1.1 404") },
      "plain HTTP never serves the app itself")
let profile = curl(["http://127.0.0.1:8765/Relay.mobileconfig"])
check(profile.contains("application/x-apple-aspen-config") && profile.contains("com.apple.security.root"),
      "the certificate profile is offered for setup")
check(curl(["-H", "Host: evil.example:8765", "http://127.0.0.1:8765/pair"]).hasPrefix("HTTP/1.1 404"),
      "pairing page refused for a foreign Host header (DNS rebinding)")
let pair = curl(["http://localhost:8765/pair"])
check(pair.hasPrefix("HTTP/1.1 200") && pair.contains("frame-ancestors 'none'"), "pairing page served to this Mac")
check(curl(["-X", "POST", "http://127.0.0.1:8765/"]).hasPrefix("HTTP/1.1 405"), "only GET and HEAD are accepted")

// 7b. Relay's certificate authority can only vouch for local web servers.
let caText: String = {
    let p = Process(), pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    p.arguments = ["x509", "-inform", "DER", "-noout", "-text", "-in", RelayTrust.caURL.path]
    p.standardOutput = pipe; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
}()
check(caText.contains("Name Constraints: critical") && caText.contains("DNS:local") && caText.contains("DNS:localhost")
      && caText.contains("IP:192.168.0.0/255.255.0.0") && !caText.contains("IP:0.0.0.0"),
      "the CA is name-constrained to local names and private addresses")
check(caText.contains("email:invalid") && caText.contains("URI:.invalid"), "the CA can't vouch for email or URI identities")
check(caText.contains("TLS Web Server Authentication") && !caText.contains("Code Signing"), "the CA is limited to web servers")

// 8. The pairing code is never written to the log (since Relay last started).
let log = (try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/Relay/relay.log"), encoding: .utf8)) ?? ""
let sinceStart = log.components(separatedBy: "Phone page:").last ?? log
check(!sinceStart.contains(code), "the pairing code isn't in the log")
let mode = (try? FileManager.default.attributesOfItem(atPath: FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Relay/pairing-code").path)[.posixPermissions] as? Int) ?? 0
check(mode == 0o600, "the pairing code file is readable only by you")

client.cancel(with: .normalClosure, reason: nil)
print(failures == 0 ? "PASS: security checks" : "FAIL: \(failures) security checks failed")
exit(failures == 0 ? 0 : 1)
