import AppKit
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
let power = Power(queue: queue)
let webServer: WebServer
let controlServer: ControlServer

do {
    webServer = try WebServer(port: webPort, root: resolveWebRoot(), queue: queue)
    controlServer = try ControlServer(port: controlPort, queue: queue, pairing: pairing, input: input,
                                      keyboard: keyboard, power: power)
} catch {
    Log.info("Relay failed to start: \(error)")
    exit(1)
}
let hostName = (SCDynamicStoreCopyLocalHostName(nil) as String?) ?? "localhost"
// The pairing link carries the code in the URL fragment (#k=…), which browsers never send
// over the network; the page reads it locally. Built on demand so a new code shows at once.
webServer.pairingPage = {
    let code = pairing.code
    return PairingPage.html(url: "http://\(hostName).local:\(webPort)/#k=\(code)", code: code)
}
webServer.start()
controlServer.start()

if !input.hasPermission {
    Log.info("Accessibility permission missing — opening the system prompt. Enable Relay in System Settings › Privacy & Security › Accessibility.")
    _ = CGRequestPostEventAccess()
}

Log.info("Relay started (pid \(getpid()), web root \(resolveWebRoot().path))")
// The pairing code is deliberately never written to the log.
Log.info("Phone page: http://\(hostName).local:\(webPort)")
Log.info("QR code to scan: http://localhost:\(webPort)/pair")

// Menu bar app: no Dock icon or windows, just the status item.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBar = MenuBar(pairingURL: URL(string: "http://localhost:\(webPort)/pair")!) { paused in
    controlServer.setPaused(paused)
}
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
