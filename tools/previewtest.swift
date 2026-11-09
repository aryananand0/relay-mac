import CoreGraphics
import Foundation
// Screen preview checks (needs Screen Recording permission for Relay):
// 1. Auto mode: a layout arrives, JPEG frames arrive, and at rest no more than about one
//    frame per second is sent.
// 2. With two or more screens: moving the cursor to another screen makes Auto switch to it
//    (the cursor is put back afterwards).
let code = CommandLine.arguments[1]
let t = RelayClient()
t.resume()
func say(_ m: String) async throws { try await t.send(.string(m)) }
var failures = 0
func check(_ ok: Bool, _ what: String) { print("\(ok ? "PASS" : "FAIL"): \(what)"); if !ok { failures += 1 } }

/// Everything received, recorded by a background reader (the screen may be still, so the
/// test never blocks waiting for a message).
final class Inbox: @unchecked Sendable {
    private let lock = NSLock()
    private var layouts: [String] = [], frames: [Int: Int] = [:], badJPEG = false
    func add(_ text: String) { lock.lock(); if text.hasPrefix("S ") { layouts.append(text) }; lock.unlock() }
    func add(_ d: Data) {
        lock.lock(); frames[Int(d[0]), default: 0] += 1
        if !(d.count > 3 && d[1] == 0xFF && d[2] == 0xD8) { badJPEG = true }; lock.unlock()
    }
    /// Returns and clears what arrived so far.
    func take() -> (layouts: [String], frames: [Int: Int], jpegs: Bool) {
        lock.lock(); defer { layouts = []; frames = [:]; badJPEG = false; lock.unlock() }
        return (layouts, frames, !badJPEG)
    }
}
let inbox = Inbox()

func listen(_ seconds: Double) async throws -> (layouts: [String], frames: [Int: Int], jpegs: Bool) {
    try await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
    return inbox.take()
}

try await say("a \(code)"); _ = try await t.receive()
_ = Task {
    while true {
        switch try await t.receive() {
        case .string(let s): inbox.add(s)
        case .data(let d): inbox.add(d); try await say("i ack \(d[0])")
        @unknown default: break
        }
    }
}
_ = Task { while true { try await say("p 0"); try await Task.sleep(nanoseconds: 1_500_000_000) } }
let home = CGEvent(source: nil)!.location
try await say("i on 800 -2")
let rest = try await listen(5)
if rest.layouts.first == "S denied" { print("CHECK: Relay has no Screen Recording permission"); exit(0) }
let parts = rest.layouts.first?.split(separator: " ") ?? []
let rects = parts.dropFirst(6).map { $0.split(separator: ",").compactMap { Double($0) } }
    .map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) }
let shown = parts.count > 5 ? Int(parts[5]) ?? -9 : -9
let total = rest.frames.values.reduce(0, +)
check(!rects.isEmpty, "layout received (\(rects.count) screens)")
check(rects.indices.contains(shown) && rects[shown].contains(home), "Auto shows the screen the cursor is on (screen \(shown + 1))")
check(total >= 1 && rest.jpegs && rest.frames.keys.allSatisfy { $0 == shown }, "JPEG frames for that screen only")
check(total <= 7, "at rest about 1 frame per second (\(total) in 5 s)")

if rects.count > 1 {
    let other = (shown + 1) % rects.count
    let target = CGPoint(x: rects[other].midX, y: rects[other].midY)
    try await say("j \(target.x) \(target.y)")
    let moved = try await listen(2.5)
    let switched = moved.layouts.contains { $0.split(separator: " ").count > 5 && Int($0.split(separator: " ")[5]) == other }
    check(switched, "Auto switched to screen \(other + 1) when the cursor moved there")
    check(moved.frames[other, default: 0] >= 1, "frames now come from screen \(other + 1)")
    try await say("j \(home.x) \(home.y)")
    _ = try await listen(1)
} else {
    print("(one screen: skipped the Auto switching check)")
}
try await say("i off")
t.cancel(with: .normalClosure, reason: nil)
print(failures == 0 ? "PASS: screen preview" : "FAIL: \(failures) preview checks failed")
