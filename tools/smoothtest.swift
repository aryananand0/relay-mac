import CoreGraphics
import Foundation
// Streams 60 Hz cursor moves to Relay with Wi-Fi-like jitter (same seed every run),
// samples the real cursor at ~2 kHz, and reports how evenly it moved per 120 Hz frame.
let code = CommandLine.arguments[1]
let smooth = CommandLine.arguments[2]

struct LCG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) } }
var rng = LCG(s: 42)
let packets = 120, step = 5.0, interval = 1.0 / 60
// Arrival schedule: nominal 60 Hz + 0–6 ms jitter, and every 12th packet held up 28 ms (a Wi-Fi hiccup).
var sendAt: [Double] = []
for i in 0..<packets {
    let nominal: Double = Double(i) * interval
    let jitter: Double = rng.next() * 0.006
    let hiccup: Double = (i % 12 == 5) ? 0.028 : 0
    sendAt.append(nominal + jitter + hiccup)
}
sendAt.sort()

// Record every mouse-moved event the window server receives (listen-only tap).
final class Samples: @unchecked Sendable { var t: [Double] = []; var x: [Double] = []; let lock = NSLock() }
let samples = Samples()
let tapThread = Thread {
    let mask = CGEventMask(1 << CGEventType.mouseMoved.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
        eventsOfInterest: mask, callback: { _, _, e, _ in
            samples.lock.lock(); samples.t.append(CFAbsoluteTimeGetCurrent()); samples.x.append(e.location.x); samples.lock.unlock()
            return Unmanaged.passUnretained(e)
        }, userInfo: nil) else { print("no event tap"); exit(2) }
    CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CFRunLoopRun()
}
tapThread.start()

let t = RelayClient()
t.resume()
try await t.send(.string("a \(code)")); _ = try await t.receive()
try await t.send(.string("o smooth \(smooth)")); try await t.send(.string("o reserve \(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "0")"))
try await t.send(.string("m -4000 -4000")); try await Task.sleep(nanoseconds: 300_000_000)
try await t.send(.string("m 300 400")); try await Task.sleep(nanoseconds: 600_000_000)
samples.lock.lock(); samples.t.removeAll(); samples.x.removeAll(); samples.lock.unlock()
let x0 = CGEvent(source: nil)!.location.x
let start = CFAbsoluteTimeGetCurrent()
for at in sendAt {
    let wait = start + at - CFAbsoluteTimeGetCurrent()
    if wait > 0 { usleep(UInt32(wait * 1_000_000)) }
    try await t.send(.string("m \(step) 0"))
}
try await Task.sleep(nanoseconds: 300_000_000)
try await t.send(.string("o smooth 1"))
t.cancel(with: .normalClosure, reason: nil)

// Cursor x at each 120 Hz frame boundary.
func xAt(_ time: Double) -> Double { var v = x0; for (i, ts) in samples.t.enumerated() where ts <= time { v = samples.x[i] }; return v }
let firstMove = samples.t.first!
let frame = 1.0 / 120
var steps: [Double] = []
var f = start
while f < start + sendAt.last! + 0.03 { steps.append(xAt(f + frame) - xAt(f)); f += frame }
let mid = Array(steps.dropFirst(4).dropLast(4))
let mean = mid.reduce(0, +) / Double(mid.count)
let sd = (mid.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(mid.count)).squareRoot()
print(String(format: "reserve=%@ms ", CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "0") + String(format: "smooth=%@  first move after %.1f ms | per-frame step: mean %.2f px, unevenness (CV) %.2f, frozen frames %d, biggest jump %.1f px | total %.0f / %.0f px",
             smooth, (firstMove - start) * 1000, mean, sd / mean, mid.filter { $0 == 0 }.count, mid.max()!, samples.x.last! - x0, Double(packets) * step))
