import Foundation
import Network

/// Minimal static file server for the iPhone web app (GET/HEAD only).
final class WebServer {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let root: URL
    private let port: UInt16
    /// Served at /pair, to this Mac only.
    var pairingPage: (() -> Data)?

    private static let contentTypes = [
        "html": "text/html; charset=utf-8",
        "js": "text/javascript; charset=utf-8",
        "css": "text/css; charset=utf-8",
        "json": "application/json",
        "webmanifest": "application/manifest+json",
        "png": "image/png",
        "svg": "image/svg+xml",
    ]

    init(port: UInt16, root: URL, queue: DispatchQueue) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
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

    private func respond(_ connection: NWConnection, head: String) {
        let requestLine = head.split(separator: "\r\n", maxSplits: 1).first ?? ""
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" || parts[0] == "HEAD" else {
            return send(connection, status: "405 Method Not Allowed", type: "text/plain", body: Data("405".utf8))
        }
        var path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "/")
        if path == "/" { path = "/index.html" }
        if path == "/pair" {
            // Also require a literal localhost Host header, so a web page using DNS
            // rebinding can't read the pairing code from a browser on this Mac.
            let host = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("host:") }?
                .dropFirst(5).trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            let localHosts = ["localhost:\(port)", "127.0.0.1:\(port)", "[::1]:\(port)"]
            guard PeerPolicy.isLoopback(connection.endpoint), localHosts.contains(host),
                  let page = pairingPage?() else {
                return send(connection, status: "404 Not Found", type: "text/plain", body: Data("404".utf8))
            }
            return send(connection, status: "200 OK", type: "text/html; charset=utf-8", body: page)
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

    private func send(_ connection: NWConnection, status: String, type: String, body: Data, length: Int? = nil) {
        let header = """
        HTTP/1.1 \(status)\r
        Content-Type: \(type)\r
        Content-Length: \(length ?? body.count)\r
        Cache-Control: no-store\r
        X-Content-Type-Options: nosniff\r
        Connection: close\r
        \r

        """
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
    }
}
