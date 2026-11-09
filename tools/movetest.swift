import Foundation
import CoreGraphics
// Moves the cursor in a burst like a real swipe and checks every delta lands.
let code = CommandLine.arguments[1]
let t = RelayClient()
t.resume()
try await t.send(.string("a \(code)"))
guard case .string(let reply) = try await t.receive(), reply == "ok" else { print("auth failed"); exit(1) }
try await t.send(.string("p 1"))
if case .string(let s) = try await t.receive() { print("ping ->", s) }
// Park the cursor somewhere central first.
try await t.send(.string("m -4000 -4000")); try await Task.sleep(nanoseconds: 400_000_000)
try await t.send(.string("m 400 300")); try await Task.sleep(nanoseconds: 400_000_000)
let start = CGEvent(source: nil)!.location
for _ in 0..<60 {                       // 60 moves of (+3, +2) at ~120 Hz
    try await t.send(.string("m 3 2"))
    try await Task.sleep(nanoseconds: 8_000_000)
}
try await Task.sleep(nanoseconds: 300_000_000)
let end = CGEvent(source: nil)!.location
print(String(format: "burst moved dx=%.1f dy=%.1f (expected 180.0, 120.0)", end.x - start.x, end.y - start.y))
t.cancel(with: .normalClosure, reason: nil)
