import AppKit
// Opens a text window, has Relay type into it, and compares the result.
// Aborts before every command if this window is not frontmost, so keystrokes
// can never land in another app.
let code = CommandLine.arguments[1]
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(contentRect: NSRect(x: 200, y: 300, width: 560, height: 160),
                      styleMask: [.titled], backing: .buffered, defer: false)
window.title = "Relay typing test"
let text = NSTextView(frame: window.contentView!.bounds)
text.isAutomaticSpellingCorrectionEnabled = false
text.isAutomaticTextReplacementEnabled = false
text.isAutomaticQuoteSubstitutionEnabled = false
text.isAutomaticDashSubstitutionEnabled = false
text.isContinuousSpellCheckingEnabled = false
text.font = .systemFont(ofSize: 16)
window.contentView!.addSubview(text)

let steps: [(String, Int)] = [
    ("t Hello, world!", 1), ("k return -", 1), ("t ünïcödé 🎉 café ", 1),
    ("t abcdefghijklmnopqrstuvwxyz0123456789", 1), ("k delete -", 3), ("k left -", 2),
    ("t X", 1), ("k left cmd", 1), ("t >", 1),
]
let expected = "Hello, world!\n>ünïcödé 🎉 café abcdefghijklmnopqrstuvwxyz01234X56"

func frontmost() -> Bool {
    NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() && window.isKeyWindow
        && window.firstResponder === text
}

DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(text)
    app.activate(ignoringOtherApps: true)
    Task { @MainActor in
        try await Task.sleep(nanoseconds: 800_000_000)
        guard frontmost() else { print("ABORT: test window is not frontmost; nothing sent"); exit(2) }
        let t = RelayClient()
        t.resume()
        try await t.send(.string("a \(code)"))
        _ = try await t.receive()
        for (cmd, times) in steps {
            for _ in 0..<times {
                guard frontmost() else { print("ABORT: focus moved away; stopped before \(cmd)"); exit(2) }
                try await t.send(.string(cmd))
                try await Task.sleep(nanoseconds: 60_000_000)
            }
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let got = text.string
        print("got:      \(got.debugDescription)")
        print("expected: \(expected.debugDescription)")
        print(got == expected ? "PASS" : "FAIL")
        t.cancel(with: .normalClosure, reason: nil)
        exit(got == expected ? 0 : 1)
    }
}
app.run()
