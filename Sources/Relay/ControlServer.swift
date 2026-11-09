import CryptoKit
import Foundation
import Network
import SystemConfiguration

/// WebSocket endpoint the iPhone sends input commands to.
///
/// Pairing and encryption (SecureChannel): Relay opens with "n <nonce> <public key> <salt>
/// <iterations>"; the phone answers "a <nonce> <public key> <proof>" (→ "no" or "paused" in
/// plaintext on failure, or "wait" while that address is locked out after wrong attempts). From then on every
/// message both ways is encrypted; the commands below are what's inside. A phone that hasn't
/// paired within 10 seconds is disconnected.
///
/// Protocol: one space-separated text message per command.
///                   → "ok" once paired
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
///   i on <px> <n>   open the screen preview, each screen <px> wide on the phone; n: -2 follow
///                   the cursor, -1 all screens, else that screen
///                   → "S <desktop x y w h> <shown> <x,y,w,h per screen>" (again whenever the
///                   followed screen changes), "S denied", or later "S paused" (untouched 3 min),
///                   then binary frames: 1 byte screen index + JPEG, and "C x y" cursor positions
///   i ack <n>       the phone has shown screen n's last frame (only then is the next sent)
///   i off           close the screen preview
///   j <x> <y>       put the cursor at a point in Mac screen points (tap on the preview)
///   p <token>       ping                               → "P <token> <ax>"  (ax: 1 if Accessibility granted)
final class ControlServer {
    private let listener: NWListener
    private let queue: DispatchQueue
    private let pairing: Pairing
    private let input: InputInjector
    private let keyboard: KeyboardInjector
    private let power: Power
    private let preview = ScreenPreview()
    /// The phone currently watching the screen preview (control queue).
    private var previewOwner: ObjectIdentifier?
    private var lastPreviewBoost: CFAbsoluteTime = 0
    private var lastCursorSent: CFAbsoluteTime = 0
    private var cursorTimer: DispatchWorkItem?
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
            if value {
                stopPreview()
                for session in sessions.values { session.close(saying: "paused") }
            }
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

    private func stopPreview() {
        guard previewOwner != nil else { return }
        previewOwner = nil
        preview.stop()
    }

    /// Input from the phone watching the preview: show its effect promptly.
    fileprivate func previewActivity(from session: Session) {
        guard previewOwner == ObjectIdentifier(session) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastPreviewBoost > 0.5 else { return }
        lastPreviewBoost = now
        preview.activity()
    }

    /// Tells the previewing phone where the cursor is: at most every 50 ms while it moves,
    /// plus once shortly after it stops so the final position is exact.
    fileprivate func previewCursorMoved() {
        guard previewOwner != nil else { return }
        let now = CFAbsoluteTimeGetCurrent()
        cursorTimer?.cancel()
        if now - lastCursorSent >= 0.05 {
            lastCursorSent = now
            preview.cursor(input.location)
        }
        let settle = DispatchWorkItem { [weak self] in
            guard let self, self.previewOwner != nil else { return }
            self.preview.cursor(self.input.location)
        }
        cursorTimer = settle
        queue.asyncAfter(deadline: .now() + 0.08, execute: settle)
    }

    /// After a new pairing code: every phone has to pair again. Thread-safe.
    func disconnectAll() {
        queue.async { [self] in
            stopPreview()
            for session in sessions.values { session.connection.cancel() }
        }
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
        if previewOwner == ObjectIdentifier(session) { stopPreview() }
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
        private let macNonce = SecureChannel.randomNonce()
        private let macSecret = Curve25519.KeyAgreement.PrivateKey()   // fresh for every connection
        private let lockoutKey: String
        /// Set once paired. Guarded by sendLock for sending (frames come from another queue);
        /// opening only happens on the control queue.
        private var channel: SecureChannel?
        private let sendLock = NSLock()

        init(connection: NWConnection, server: ControlServer) {
            self.connection = connection
            self.server = server
            peer = PeerPolicy.hostKey(connection.endpoint)
            lockoutKey = PeerPolicy.lockoutKey(connection.endpoint)
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
            sendPlain("n \(macNonce.hex) \(macSecret.publicKey.rawRepresentation.hex) \(server.pairing.stretchParameters)")
            receive()
            // Don't let unpaired connections linger.
            queue.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self, !self.authenticated else { return }
                self.connection.cancel()
            }
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
                if let data, !data.isEmpty {
                    if !self.authenticated, meta?.opcode == .text {
                        self.pair(String(decoding: data, as: UTF8.self))
                    } else if self.authenticated, meta?.opcode == .binary,
                              let plain = self.sendLock.withLock({ self.channel?.open(data) }),
                              plain.first == UInt8(ascii: "T") {
                        self.handle(String(decoding: plain.dropFirst(), as: UTF8.self))
                    } else {
                        // Anything else (plaintext after pairing, a forged, replayed or
                        // reordered message) ends the connection.
                        Log.info("control: \(self.peer) sent an invalid message; disconnecting")
                        self.connection.cancel()
                        return
                    }
                }
                self.receive()
            }
        }

        /// "a <phone nonce> <phone public key> <proof>": the phone proves it knows the pairing code.
        private func pair(_ text: String) {
            if server.paused {
                close(saying: "paused")
                return
            }
            let parts = text.split(separator: " ")
            var accepted: SecureChannel?
            var outcome = Pairing.Outcome.wrong
            if parts.count == 4, parts[0] == "a", let phoneNonce = Data(hex: parts[1]),
               let phonePublic = Data(hex: parts[2]), let proof = Data(hex: parts[3]) {
                outcome = server.pairing.authenticate(peer: lockoutKey) { stretched in
                    accepted = SecureChannel.accept(stretched: stretched, macNonce: macNonce, macSecret: macSecret,
                                                    phoneNonce: phoneNonce, phonePublic: phonePublic, proof: proof)
                    return accepted != nil
                }
            }
            guard let accepted else {
                Log.info("control: \(peer) \(outcome == .lockedOut ? "is locked out" : "failed pairing")")
                sendPlain(outcome == .lockedOut ? "wait" : "no")
                // Short delay slows guessing and lets "no" reach the client.
                server.queue.asyncAfter(deadline: .now() + 0.5) { [connection] in connection.cancel() }
                return
            }
            sendLock.withLock { channel = accepted }
            authenticated = true
            server.controllerCountChanged(by: 1)
            send("ok")
            Log.info("control: \(peer) paired (accessibility: \(server.input.hasPermission))")
        }

        private func handle(_ text: String) {
            let parts = text.split(separator: " ")
            guard let command = parts.first else { return }

            // Clicks, scrolling and typing change the screen: show the result promptly. Plain
            // cursor movement doesn't need new frames (its position is sent separately).
            if "scdukt".contains(command) { server.previewActivity(from: self) }
            if command == "m" || command == "j" { server.previewCursorMoved() }
            if command == "f" {
                for delay in [0.1, 0.3] {   // find my cursor jumps it to the centre
                    server.queue.asyncAfter(deadline: .now() + delay) { [weak server] in server?.previewCursorMoved() }
                }
            }
            switch command {
            case "i":
                guard parts.count >= 2 else { return }
                switch parts[1] {
                case "on":
                    let px = parts.count >= 3 ? Int(parts[2]) ?? 1000 : 1000
                    let mode = ScreenPreview.Mode(parts.count >= 4 ? Int(parts[3]) ?? -2 : -2)
                    server.previewOwner = ObjectIdentifier(self)
                    server.preview.start(widthPx: px, mode: mode,
                                         sendText: { [weak self] in self?.send($0) },
                                         sendData: { [weak self] in self?.sendData($0) })
                case "ack":
                    if parts.count >= 3, let n = Int(parts[2]), server.previewOwner == ObjectIdentifier(self) {
                        server.preview.ack(n)
                    }
                case "off":
                    if server.previewOwner == ObjectIdentifier(self) { server.stopPreview() }
                default: break
                }
            case "j":
                guard parts.count >= 3, let x = Double(parts[1]), let y = Double(parts[2]),
                      x.isFinite, y.isFinite, abs(x) < 100_000, abs(y) < 100_000 else { return }
                server.input.moveTo(CGPoint(x: x, y: y))
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
                if server.previewOwner == ObjectIdentifier(self) { server.preview.heard() }
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

        /// A screen-preview frame (encrypted).
        func sendData(_ data: Data) { sendSealed(Data("F".utf8) + data) }

        /// A command or status message: encrypted once paired, plaintext before ("no", "paused").
        func send(_ text: String) {
            if authenticated { sendSealed(Data("T".utf8) + Data(text.utf8)) } else { sendPlain(text) }
        }

        /// Seals and sends under one lock, so message counters and send order always agree
        /// even when frames are sent from the preview queue.
        private func sendSealed(_ plain: Data) {
            sendLock.withLock {
                guard let sealed = channel?.seal(plain) else { return }
                let meta = NWProtocolWebSocket.Metadata(opcode: .binary)
                let context = NWConnection.ContentContext(identifier: "sealed", metadata: [meta])
                connection.send(content: sealed, contentContext: context, isComplete: true,
                                completion: .contentProcessed { _ in })
            }
        }

        private func sendPlain(_ text: String) {
            let meta = NWProtocolWebSocket.Metadata(opcode: .text)
            let context = NWConnection.ContentContext(identifier: "text", metadata: [meta])
            connection.send(content: Data(text.utf8), contentContext: context, isComplete: true,
                            completion: .contentProcessed { _ in })
        }
    }
}
