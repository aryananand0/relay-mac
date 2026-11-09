import AppKit
// Checks keep awake, the sleep timer (dry run: the Mac does not actually sleep),
// the clipboard (your clipboard is saved and restored), and find my cursor.
let code = CommandLine.arguments[1]
let t = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8766/")!)
t.resume()
func say(_ m: String) async throws { try await t.send(.string(m)) }
func hear() async throws -> String { if case .string(let s) = try await t.receive() { return s }; return "" }
func heldByRelay() -> Bool {
    let p = Process(); let pipe = Pipe()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset"); p.arguments = ["-g", "assertions"]
    p.standardOutput = pipe; try? p.run(); p.waitUntilExit()
    return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        .contains("Relay: keeping the Mac awake")
}
var failures = 0
func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL"): \(what)"); if !ok { failures += 1 } }

try await say("a \(code)"); _ = try await hear()
try await say("o dryrun 1")

try await say("q power"); check(try await hear() == "W 0 0", "nothing active at start")
check(!heldByRelay(), "no sleep assertion at start")

try await say("w 60"); let w = try await hear()
check(w == "W 3600 0", "keep awake 1 hour reported (\(w))")
check(heldByRelay(), "keep awake holds a display-sleep assertion")
try await say("w on"); check(try await hear() == "W -1 0", "keep awake until turned off")
try await say("w off"); check(try await hear() == "W 0 0", "keep awake off")
check(!heldByRelay(), "assertion released")

try await say("z 0.05"); let z = try await hear()   // 3 seconds
check(z == "W 0 3", "sleep timer reported (\(z))")
check(heldByRelay(), "sleep timer keeps the Mac awake until it ends")
let ended = try await hear()
check(ended == "W 0 0", "sleep timer ended and was announced (\(ended))")
check(!heldByRelay(), "assertion released when the timer ended")
try await say("z 30"); _ = try await hear()
try await say("z off"); check(try await hear() == "W 0 0", "sleep timer cancelled")
try await say("w bogus"); try await say("q power"); check(try await hear() == "W 0 0", "bad value ignored")

// Clipboard: save every item, round-trip text, restore.
let board = NSPasteboard.general
let saved = (board.pasteboardItems ?? []).map { item in
    item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { $0[$1] = item.data(forType: $1) }
}
let sample = "Relay clipboard test é ✓ \(Int.random(in: 1000...9999))\nsecond line"
try await say("b \(sample)")
try await say("q clip"); let clip = try await hear()
check(clip == "B \(sample)", "clipboard round-trip")
check(board.string(forType: .string) == sample, "Mac clipboard holds the sent text")
board.clearContents()
board.writeObjects(saved.map { types in
    let item = NSPasteboardItem(); for (type, data) in types { item.setData(data, forType: type) }; return item
})
print("clipboard restored")

// Find my cursor: ends in the middle of the screen the cursor was on.
let start = CGEvent(source: nil)!.location
var ids = [CGDirectDisplayID](repeating: 0, count: 8); var n: UInt32 = 0
CGGetActiveDisplayList(8, &ids, &n)
let rect = ids.prefix(Int(n)).map { CGDisplayBounds($0) }.first { $0.contains(start) } ?? CGDisplayBounds(CGMainDisplayID())
try await say("f")
try await Task.sleep(nanoseconds: 600_000_000)
let end = CGEvent(source: nil)!.location
check(abs(end.x - rect.midX) < 2 && abs(end.y - rect.midY) < 2, "find cursor centred it (\(end) vs \(rect.midX),\(rect.midY))")

try await say("o dryrun 0")
t.cancel(with: .normalClosure, reason: nil)
print(failures == 0 ? "PASS: all power, clipboard and cursor checks" : "FAIL: \(failures) checks failed")
