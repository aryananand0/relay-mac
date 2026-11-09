import Foundation
import Network

/// Minimal web server (GET/HEAD only), in one of two roles:
/// - **app** (HTTPS, port 8443): the phone page itself, plus /ping for the setup page's check.
/// - **setup** (plain HTTP, port 8765): only what a phone needs before it trusts Relay's
///   certificate: the setup page, the certificate profile, and the icons. Nothing secret is
///   ever served over plain HTTP. /pair (the QR codes with the pairing code) is served to this
///   Mac itself only.
final class WebServer {
    enum Role { case app, setup }

    private let listener: NWListener
    private let queue: DispatchQueue
    private let root: URL
    private let port: UInt16
    private let role: Role
    /// Served at /pair, to this Mac only (setup role).
    var pairingPage: (() -> Data)?
    /// Required as /pair?t=<token>, so only this user's processes can open the pairing page.
    var pairingToken: String?
    /// Served at / and /setup (setup role).
    var setupPage: (() -> Data)?
    /// Served at /Relay.mobileconfig (setup role).
    var profile: Data?

    private static let contentTypes = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "webmanifest": "application/manifest+json",
        "png": "image/png",
        "svg": "image/svg+xml",
    ]

    /// The phone page may only run its own scripts and styles, load its own images (and the
    /// preview frames it decodes itself), and talk to Relay's control port.
    private static let appPolicy = "default-src 'none'; script-src 'self'; style-src 'self'; "
        + "img-src 'self' blob:; connect-src wss://*:8766; manifest-src 'self'; base-uri 'none'; "
        + "form-action 'none'; frame-ancestors 'none'"
    /// The pairing page (this Mac only) has inline styles and an inline QR image.
    private static let pairPolicy = "default-src 'none'; style-src 'unsafe-inline'; img-src 'self' data:; "
        + "base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    /// The setup page checks (from plain HTTP) whether the HTTPS page is reachable yet.
    private static let setupPolicy = "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
        + "img-src 'self'; connect-src https://*:8443; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"

    init(port: UInt16, root: URL, queue: DispatchQueue, role: Role, tls: NWProtocolTLS.Options? = nil) throws {
        let params = tls.map { NWParameters(tls: $0, tcp: NWProtocolTCP.Options()) } ?? NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.role = role
        self.port = port
        self.root = root.standardizedFileURL
        self.queue = queue
    }

    func start() {
        listener.stateUpdateHandler = { state in Log.info("web listener: \(state)") }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            guard PeerPolicy.isAllowed(connection.endpoint) else {
                Log.info("web: rejected \(connection.endpoint)")
                connection.cancel()
                return
            }
            connection.start(queue: self.queue)
            self.read(connection, buffer: Data())
        }
        listener.start(queue: queue)
    }

    private func read(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.respond(connection, head: String(decoding: buffer[..<end.lowerBound], as: UTF8.self))
            } else if error != nil || isComplete || buffer.count > 16_384 {
                connection.cancel()
            } else {
                self.read(connection, buffer: buffer)
            }
        }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        return zip(x, y).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private func respond(_ connection: NWConnection, head: String) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return send(connection, status: "405 Method Not Allowed", type: "text/plain", body: Data("405".utf8))
        }
        let target = parts[1].split(separator: "?", maxSplits: 1)
        var path = String(target.first ?? "/")
        let query = target.count > 1 ? String(target[1]) : ""
        let notFound = { self.send(connection, status: "404 Not Found", type: "text/plain", body: Data("404".utf8)) }

        if role == .app {
            if path == "/ping" { return send(connection, status: "204 No Content", type: "text/plain", body: Data()) }
            if path == "/" { path = "/index.html" }
        } else {
            switch path {
            case "/", "/setup", "/index.html":
                guard let page = setupPage?() else { return notFound() }
                return send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: page,
                            policy: WebServer.setupPolicy)
            case "/Relay.mobileconfig":
                guard let profile else { return notFound() }
                return send(connection, status: "200 OK", type: "application/x-apple-aspen-config", body: profile,
                            extraHeaders: "Content-Disposition: attachment; filename=\"Relay.mobileconfig\"\r\n")
            case "/pair":
                break
            case "/logo.svg", "/icon.png":
                break   // static, below
            default:
                return notFound()
            }
        }
        if path == "/pair" {
            guard role == .setup else { return notFound() }
            // Also require a literal localhost Host header, so a web page using DNS
            // rebinding can't read the pairing code from a browser on this Mac.
            let host = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("host:") }?
                .dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let localHosts = ["localhost:\(port)", "127.0.0.1:\(port)", "[::1]:\(port)"]
            let token = query.split(separator: "&").first { $0.hasPrefix("t=") }.map { String($0.dropFirst(2)) } ?? ""
            guard PeerPolicy.isLoopback(connection.endpoint), localHosts.contains(host),
                  let expected = pairingToken, WebServer.constantTimeEqual(token, expected),
                  let page = pairingPage?() else {
                return send(connection, status: "404 Not Found", type: "text/plain", body: Data("404".utf8))
            }
            return send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: page,
                        policy: WebServer.pairPolicy)
        }

        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_./")
        let file = root.appendingPathComponent(String(path.dropFirst())).standardizedFileURL
        guard path.unicodeScalars.allSatisfy(allowed.contains), !path.contains(".."),
              file.path.hasPrefix(root.path + "/"),
              let body = try? Data(contentsOf: file) else {
            return send(connection, status: "404 Not Found", type: "text/plain", body: Data("404".utf8))
        }
        let type = WebServer.contentTypes[file.pathExtension.lowercased()] ?? "application/octet-stream"
        send(connection, status: "200 OK", type: type, body: parts[0] == "HEAD" ? Data() : body,
             length: body.count)
    }

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, length: Int? = nil,
                      policy: String = WebServer.appPolicy, extraHeaders: String = "") {
        // No HSTS: it applies to every port on the host, and would push the plain-HTTP setup
        // page (port 8765) onto HTTPS too.
        let header = """
        HTTP/1.1 \(status)\r
        \(extraHeaders)Content-Type: \(type)\r
        Content-Length: \(length ?? body.count)\r
        Cache-Control: no-store\r
        Content-Security-Policy: \(policy)\r
        X-Content-Type-Options: nosniff\r
        X-Frame-Options: DENY\r
        Referrer-Policy: no-referrer\r
        Cross-Origin-Resource-Policy: same-origin\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
