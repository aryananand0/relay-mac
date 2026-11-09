import CoreGraphics
import Foundation
// Turns the displays off through Relay, then sends one small cursor move and checks they wake.
let code = CommandLine.arguments[1]
func asleep() -> Bool { CGDisplayIsAsleep(CGMainDisplayID()) != 0 }
let t = RelayClient()
t.resume()
try await t.send(.string("a \(code)")); _ = try await t.receive()
print("display asleep before: \(asleep())")
try await t.send(.string("y displaysleep"))
try await Task.sleep(nanoseconds: 2_000_000_000)
print("2 s after 'display off': asleep = \(asleep())")
try await t.send(.string("m 2 0"))
var woke = -1.0
for i in 1...40 { try await Task.sleep(nanoseconds: 50_000_000); if !asleep() { woke = Double(i) * 50; break } }
print(woke >= 0 ? "woke \(Int(woke)) ms after one touch" : "STILL ASLEEP after 2 s")
if woke < 0 { try await t.send(.string("m -2 0")) }
t.cancel(with: .normalClosure, reason: nil)
