import AppKit

/// Relay's menu bar icon: shows whether a phone is connected, and offers the
/// pairing code, a pause switch, the log, and quit. All methods run on the main thread.
final class MenuBar: NSObject {
    private static let pausedKey = "paused"

    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause Relay", action: #selector(togglePause), keyEquivalent: "")
    private let powerItem = NSMenuItem(title: "", action: #selector(cancelPower), keyEquivalent: "")
    private let pairingURL: URL
    private let onPause: (Bool) -> Void
    private var connected = 0
    /// The iPhone certificate profile, for "Send Certificate to iPhone…" (AirDrop).
    var certificateProfile: URL?
    /// Replaces the pairing code (after the user confirms).
    var onNewPairingCode: (() -> Void)?
    /// Turns off keep-awake and the sleep timer.
    var onCancelPower: (() -> Void)?
    private(set) var paused = UserDefaults.standard.bool(forKey: MenuBar.pausedKey)

    init(pairingURL: URL, onPause: @escaping (Bool) -> Void) {
        self.pairingURL = pairingURL
        self.onPause = onPause
        super.init()

        let menu = NSMenu()
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        powerItem.target = self
        powerItem.isHidden = true
        menu.addItem(powerItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Pairing Code…", action: #selector(showPairing), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Send Certificate to iPhone…", action: #selector(sendCertificate), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Pairing Code…", action: #selector(newPairingCode), keyEquivalent: "").target = self
        pauseItem.target = self
        menu.addItem(pauseItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Restart Relay", action: #selector(restart), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit Relay", action: #selector(quit), keyEquivalent: "q").target = self
        item.menu = menu
        item.button?.toolTip = "Relay"

        if paused { onPause(true) }
        refresh()
    }

    func setConnected(_ count: Int) {
        connected = count
        refresh()
    }

    /// summary: e.g. "Keeping Mac awake until 1:30 AM"; nil hides the item.
    func setPower(_ summary: String?) {
        powerItem.isHidden = summary == nil
        if let summary {
            let cancel = summary.hasPrefix("Sleep timer") ? "Cancel" : "Turn Off"
            powerItem.title = "\(summary) — \(cancel)"
        }
    }

    @objc private func cancelPower() { onCancelPower?() }

    private func refresh() {
        let state: MenuBarIcon.State = paused ? .paused : (connected > 0 ? .connected : .waiting)
        item.button?.image = MenuBarIcon.image(state)
        pauseItem.state = paused ? .on : .off
        switch state {
        case .paused: statusLine.title = "Paused: iPhones can't connect"
        case .connected: statusLine.title = connected == 1 ? "iPhone connected" : "\(connected) devices connected"
        case .waiting: statusLine.title = "Ready: open Relay on your iPhone"
        }
    }

    @objc private func showPairing() { NSWorkspace.shared.open(pairingURL) }

    /// AirDrop is an authenticated, direct transfer, so the profile can't be swapped on the way.
    @objc private func sendCertificate() {
        guard let file = certificateProfile, let airDrop = NSSharingService(named: .sendViaAirDrop) else { return }
        NSApp.activate(ignoringOtherApps: true)
        if airDrop.canPerform(withItems: [file]) {
            airDrop.perform(withItems: [file])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([file])   // AirDrop off: show the file instead
        }
    }

    @objc private func newPairingCode() {
        let alert = NSAlert()
        alert.messageText = "Create a new pairing code?"
        alert.informativeText = "Every iPhone paired with this Mac is disconnected and has to scan the new code. Do this if someone else may know the current code."
        alert.addButton(withTitle: "New Code")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        onNewPairingCode?()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [pairingURL] in NSWorkspace.shared.open(pairingURL) }
    }

    @objc private func togglePause() {
        paused.toggle()
        UserDefaults.standard.set(paused, forKey: MenuBar.pausedKey)
        onPause(paused)
        refresh()
    }

    @objc private func openLog() { NSWorkspace.shared.open(Log.fileURL) }

    /// Needed once after allowing Screen Recording, which macOS applies only to a fresh launch.
    /// Exiting with an error status makes launchd start Relay again within a few seconds.
    @objc private func restart() { exit(75) }

    /// A clean exit: launchd won't restart Relay until the next login.
    @objc private func quit() { NSApp.terminate(nil) }
}

/// The logo's dot grid as an 18 pt template image (adapts to light/dark menu bars).
enum MenuBarIcon {
    enum State { case waiting, connected, paused }

    static func image(_ state: State) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            for i in 0..<3 {
                for j in 0..<3 {
                    let center = (i == 1 && j == 1)
                    let alpha: CGFloat
                    switch state {
                    case .connected: alpha = 1                       // fully lit: a phone is driving the Mac
                    case .waiting: alpha = center ? 1 : 0.45          // the fingertip dot, resting grid
                    case .paused: alpha = 0.3                          // everything dimmed
                    }
                    let r: CGFloat = center && state != .paused ? 2.4 : 1.8
                    let x = 3 + CGFloat(i) * 6, y = 3 + CGFloat(j) * 6
                    NSColor.black.withAlphaComponent(alpha).setFill()
                    NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
                }
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Relay"
        return image
    }
}
