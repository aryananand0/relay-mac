import AppKit
import CoreGraphics
import Foundation
import SystemConfiguration

/// Plain HTTP, only for setting up a phone (setup page and certificate profile).
let webPort: UInt16 = 8765
/// HTTPS: the phone page itself.
let appPort: UInt16 = 8443
/// Secure WebSocket (wss): input and status.
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
let power = Power(queue: queue)
let hostName = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "localhost"
let setupServer: WebServer
let appServer: WebServer
let controlServer: ControlServer
let tlsIdentity: TLSIdentity

do {
    tlsIdentity = try TLSIdentity(hostName: hostName)
    setupServer = try WebServer(port: webPort, root: resolveWebRoot(), queue: queue, role: .setup)
    appServer = try WebServer(port: appPort, root: resolveWebRoot(), queue: queue, role: .app,
                              tls: tlsIdentity.serverOptions())
    controlServer = try ControlServer(port: controlPort, appPort: appPort, tls: tlsIdentity.serverOptions(),
                                      queue: queue, pairing: pairing, input: input, keyboard: keyboard, power: power)
} catch {
    Log.info("Relay failed to start: \(error)")
    exit(1)
}
let setupURL = "http://\(hostName).local:\(webPort)/"
let appURL = "https://\(hostName).local:\(appPort)/"
// The pairing link carries the code in the URL fragment (#k=…), which browsers never send
// over the network; the page reads it locally. It only ever points at the HTTPS page.
// Built on demand so a new code shows at once.
setupServer.pairingPage = {
    let code = pairing.code
    return PairingPage.html(setupURL: setupURL, appURL: "\(appURL)#k=\(code)", code: code,
                            fingerprint: tlsIdentity.caFingerprint)
}
setupServer.pairingToken = pairing.pageToken
setupServer.setupPage = { SetupPage.html(appPort: appPort) }
setupServer.profile = tlsIdentity.profile
setupServer.start()
appServer.start()
controlServer.start()

if !input.hasPermission {
    Log.info("Accessibility permission missing — opening the system prompt. Enable Relay in System Settings › Privacy & Security › Accessibility.")
    _ = CGRequestPostEventAccess()
}

Log.info("Relay started (pid \(getpid()), web root \(resolveWebRoot().path))")
// The pairing code is deliberately never written to the log.
Log.info("Phone page: \(appURL) (setup: \(setupURL))")
Log.info("Pairing page: Relay menu › Show Pairing Code…, or ./scripts/pair.sh")

// Menu bar app: no Dock icon or windows, just the status item.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBar = MenuBar(pairingURL: URL(string: "http://localhost:\(webPort)/pair?t=\(pairing.pageToken)")!) { paused in
    controlServer.setPaused(paused)
}
menuBar.certificateProfile = TLSIdentity.profileURL
menuBar.onNewPairingCode = {
    queue.async {
        pairing.reset()
        controlServer.disconnectAll()
    }
}
controlServer.onControllersChanged = { count in
    DispatchQueue.main.async { menuBar.setConnected(count) }
}
menuBar.onCancelPower = { queue.async { power.cancelAll() } }
power.onChange = {
    controlServer.broadcast(power.message)
    let summary = power.summary
    DispatchQueue.main.async { menuBar.setPower(summary) }
}
app.run()
