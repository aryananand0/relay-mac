import CoreGraphics
import Foundation
import SystemConfiguration

let webPort: UInt16 = 8765
let controlPort: UInt16 = 8766

/// Web files live in Relay.app/Contents/Resources/web; RELAY_WEB_ROOT overrides for development.
func resolveWebRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment["RELAY_WEB_ROOT"] {
        return URL(fileURLWithPath: override)
    }
    if let bundled = Bundle.main.resourceURL?.appendingPathComponent("web"),
       FileManager.default.fileExists(atPath: bundled.appendingPathComponent("index.html").path) {
        return bundled
    }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("web")
}

let queue = DispatchQueue(label: "relay.control", qos: .userInteractive)
let pairing = Pairing()
let input = InputInjector(queue: queue)
let keyboard = KeyboardInjector()
let webServer: WebServer
let controlServer: ControlServer

do {
    webServer = try WebServer(port: webPort, root: resolveWebRoot(), queue: queue)
    controlServer = try ControlServer(port: controlPort, queue: queue, pairing: pairing, input: input,
                                      keyboard: keyboard)
} catch {
    Log.info("Relay failed to start: \(error)")
    exit(1)
}
let hostName = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "localhost"
let phoneURL = "http://\(hostName).local:\(webPort)/#k=\(pairing.code)"
webServer.pairingPage = { PairingPage.html(url: phoneURL, code: pairing.code) }
webServer.start()
controlServer.start()

if !input.hasPermission {
    Log.info("Accessibility permission missing — opening the system prompt. Enable Relay in System Settings › Privacy & Security › Accessibility.")
    _ = CGRequestPostEventAccess()
}

Log.info("Relay started (pid \(getpid()), web root \(resolveWebRoot().path))")
Log.info("Pairing code: \(pairing.code)")
Log.info("Open on iPhone: \(phoneURL)")
Log.info("QR code to scan: http://localhost:\(webPort)/pair")
for ip in PeerPolicy.localIPv4Addresses() {
    Log.info("  or by IP:     http://\(ip):\(webPort)/#k=\(pairing.code)")
}

dispatchMain()
