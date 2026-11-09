import Foundation
import Network
import SystemConfiguration

/// WebSocket endpoint the iPhone sends input commands to.
///
/// Protocol: one space-separated text message per command.
///   a <code>        authenticate (must be first)      → "ok" | "no" | "paused"
///   m <dx> <dy>     move cursor by points (already accelerated by the client)
///   s <dx> <dy>     scroll by pixels, wheel convention (positive = content moves down/right)
///   c <btn> <n>     click button (0 left, 1 right) with click count n
///   d <btn> <n>     press button
///   u <btn> <n>     release button
///   t <text>        type text (everything after "t " verbatim, spaces included)
///   k <key> <mods>  press a key: return tab space delete fwddelete escape left right up down
///                   home end pageup pagedown, or one character for shortcuts ("l");
///                   mods is "-" or a list like "cmd,shift" (ctrl, opt, shift, cmd)
///   x <media>       media key: play next prev volup voldown mute
///                   (volume keys are answered with a "v" status message)
///   q vol           ask for volume status → "v <0-100|-> <muted 0|1> <output device name>"
///                   ("-" = this output's volume can't be changed from the Mac, e.g. a TV over HDMI)
///   y displaysleep  turn the displays off; the next input wakes them
///   f               find my cursor: centre it on its screen and shake it so macOS enlarges it
///   w <on|off|min>  keep the Mac awake until turned off, off, or for that many minutes
///   z <off|min>     sleep timer: in that many minutes pause playback and sleep the Mac
///   q power         ask for keep-awake/sleep-timer status → "W <awake> <sleep>" (also sent
///                   to every phone whenever it changes; see Power.message)
///   b <text>        put text on the Mac's clipboard (everything after "b ")
///   q clip          ask for the Mac's clipboard text   → "B <text>"
///   p <token>       ping                               → "P <token> <ax>"  (ax: 1 if Accessibility granted)
final class ControlServer {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let pairing: Pairing
    private let input: InputInjector
    private let keyboard: KeyboardInjector
    private let power: Power
    private var sessions: [ObjectIdentifier: Session] = [:]
    private var controllers = 0
    /// Held only while a phone is connected: opts out of App Nap so input is
    /// delivered on time, while still allowing the Mac to idle-sleep.
    private var activity: NSObjectProtocol?
    /// While paused, phones are told so and disconnected (e.g. on someone else's Wi-Fi).
    private var paused = false
    /// Called on the control queue whenever the number of connected phones changes.
    var onControllersChanged: ((Int) -> Void)?

    /// Thread-safe: hops onto the control queue.
    func setPaused(_ value: Bool) {
        queue.async { [self] in
            paused = value
            Log.info(value ? "control: paused" : "control: resumed")
            if value { for session in sessions.values { session.close(saying: "paused") } }
        }
    }

    init(port: UInt16, queue: DispatchQueue, pairing: Pairing, input: InputInjector,
         keyboard: KeyboardInjector, power: Power) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        if let tcp = params.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
            tcp.noDelay = true
        }
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = SystemControls.clipboardLimit * 4 + 16   // clipboard text, UTF-8
        // Browsers always send Origin. Only Relay's own page (served from this Mac on the
        // web port) may open the control socket, so other web pages can't even try codes.
        let webPort = port - 1
        ws.setClientRequestHandler(queue) { _, headers in
            let origin = headers.first { $0.name.lowercased() == "origin" }?.value
            guard let origin else { return .init(status: .accept, subprotocol: nil) }  // non-browser client
            let allowed = ControlServer.allowedOrigins(webPort: webPort)
            if allowed.contains(origin.lowercased()) { return .init(status: .accept, subprotocol: nil) }
            Log.info("control: rejected WebSocket from origin \(origin)")
            return .init(status: .reject, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.queue = queue
        self.pairing = pairing
        self.input = input
        self.keyboard = keyboard
        self.power = power
    }

    /// Sends a message to every paired phone. Control queue only.
    func broadcast(_ message: String) {
        for session in sessions.values where session.authenticated { session.send(message) }
    }

    static func allowedOrigins(webPort: UInt16) -> Set<String> {
        var hosts = ["localhost", "127.0.0.1", "[::1]"] + PeerPolicy.localIPv4Addresses()
        if let name = SCDynamicStoreCopyLocalHostName(nil) as String? { hosts.append("\(name).local") }
        return Set(hosts.map { "http://\($0):\(webPort)".lowercased() })
    }

    func start() {
        listener.stateUpdateHandler = { state in Log.info("control listener: \(state)") }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    private func accept(_ connection: NWConnection) {
        guard PeerPolicy.isAllowed(connection.endpoint) else {
            Log.info("control: rejected \(connection.endpoint)")
            connection.cancel()
            return
        }
        let session = Session(connection: connection, server: self)
        sessions[ObjectIdentifier(session)] = session
        session.start(queue: queue)
    }

    fileprivate func ended(_ session: Session) {
        guard sessions.removeValue(forKey: ObjectIdentifier(session)) != nil else { return }
        if session.authenticated {
            input.releaseAll()
            controllerCountChanged(by: -1)
            Log.info("control: \(session.peer) disconnected")
        }
    }

    fileprivate func controllerCountChanged(by delta: Int) {
        controllers += delta
        onControllersChanged?(controllers)
        if controllers > 0, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "iPhone is controlling the Mac")
        } else if controllers == 0, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }

    fileprivate final class Session {
        let connection: NWConnection
        let peer: String
        private(set) var authenticated = false
        private unowned let server: ControlServer

        init(connection: NWConnection, server: ControlServer) {
            self.connection = connection
            self.server = server
            peer = PeerPolicy.hostKey(connection.endpoint)
        }

        func start(queue: DispatchQueue) {
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed, .cancelled: self.server.ended(self)
                default: break
                }
            }
            connection.start(queue: queue)
            receive()
        }

        private func receive() {
            connection.receiveMessage { [weak self] data, context, _, error in
                guard let self else { return }
                if error != nil {
                    self.connection.cancel()
                    return
                }
                let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition)
                    as? NWProtocolWebSocket.Metadata
                if meta?.opcode == .close {
                    self.connection.cancel()
                    return
                }
                if let data, !data.isEmpty, meta?.opcode == .text {
                    self.handle(String(decoding: data, as: UTF8.self))
                }
                self.receive()
            }
        }

        private func handle(_ text: String) {
            let parts = text.split(separator: " ")
            guard let command = parts.first else { return }

            guard authenticated else {
                if server.paused {
                    close(saying: "paused")
                    return
                }
                if command == "a", parts.count >= 2, server.pairing.verify(String(parts[1]), peer: peer) {
                    authenticated = true
                    server.controllerCountChanged(by: 1)
                    send("ok")
                    Log.info("control: \(peer) paired (accessibility: \(server.input.hasPermission))")
                } else {
                    Log.info("control: \(peer) failed pairing")
                    send("no")
                    // Short delay slows guessing and lets "no" reach the client.
                    server.queue.asyncAfter(deadline: .now() + 0.5) { [connection] in connection.cancel() }
                }
                return
            }

            switch command {
            case "t":
                if text.count > 2 { server.keyboard.type(String(text.dropFirst(2))) }
            case "k":
                guard parts.count >= 2 else { return }
                let mods = parts.count >= 3 ? KeyboardInjector.Modifiers(list: parts[2]) : []
                if !server.keyboard.press(String(parts[1]), modifiers: mods) {
                    Log.info("control: unknown key \(parts[1])")
                }
            case "m", "s":
                guard parts.count >= 3, let dx = Double(parts[1]), let dy = Double(parts[2]),
                      dx.isFinite, dy.isFinite, abs(dx) < 5000, abs(dy) < 5000 else { return }
                if command == "m" { server.input.move(dx: dx, dy: dy) }
                else { server.input.scroll(dx: dx, dy: dy) }
            case "c", "d", "u":
                guard parts.count >= 3, let b = Int(parts[1]), let button = InputInjector.Button(rawValue: b),
                      let n = Int(parts[2]), (1...3).contains(n) else { return }
                switch command {
                case "c": server.input.click(button, count: n)
                case "d": server.input.press(button, count: n)
                default: server.input.release(button, count: n)
                }
            case "x":
                guard parts.count >= 2 else { return }
                let key = String(parts[1])
                server.input.flushMotion()
                guard SystemControls.pressMediaKey(key) else {
                    Log.info("control: unknown media key \(key)")
                    return
                }
                if SystemControls.isVolumeKey(key) {
                    // Give Core Audio a moment to apply the change before reporting it.
                    server.queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        self?.send(SystemControls.volumeStatus().message)
                    }
                }
            case "q":
                guard parts.count >= 2 else { return }
                switch parts[1] {
                case "vol": send(SystemControls.volumeStatus().message)
                case "power": send(server.power.message)
                case "clip": send("B " + SystemControls.clipboardText())
                default: break
                }
            case "b":
                guard text.count > 2 else { return }
                let clip = String(text.dropFirst(2).prefix(SystemControls.clipboardLimit))
                SystemControls.setClipboard(clip)
                Log.info("control: \(peer) set the clipboard (\(clip.count) characters)")
            case "f":
                server.input.locate()
            case "w", "z":
                guard parts.count >= 2 else { return }
                let arg = String(parts[1])
                let minutes: Double?
                if arg == "off" { minutes = nil }
                else if arg == "on", command == "w" { minutes = 0 }
                else if let m = Double(arg), m > 0, m <= 24 * 60 { minutes = m }
                else { return }
                if command == "w" { server.power.keepAwake(minutes: minutes) }
                else { server.power.sleepTimer(minutes: minutes) }
            case "y":
                if parts.count >= 2, parts[1] == "displaysleep" {
                    Log.info("control: \(peer) turned the displays off")
                    SystemControls.sleepDisplays()
                }
            case "o":
                // Tuning: "o smooth 0|1" toggles motion pacing, "o reserve <ms>" sets its reserve.
                if parts.count >= 3, parts[1] == "smooth" { server.input.smoothing = parts[2] != "0" }
                if parts.count >= 3, parts[1] == "reserve", let ms = Double(parts[2]), (0...50).contains(ms) {
                    server.input.reserve = ms / 1000
                }
                if parts.count >= 3, parts[1] == "dryrun" { server.power.dryRun = parts[2] != "0" }
            case "p":
                let token = parts.count >= 2 ? parts[1] : ""
                send("P \(token) \(server.input.hasPermission ? 1 : 0)")
            default:
                break
            }
        }

        func close(saying message: String) {
            send(message)
            server.queue.asyncAfter(deadline: .now() + 0.3) { [connection] in connection.cancel() }
        }

        func send(_ text: String) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }
}
