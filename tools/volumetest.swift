import Foundation
// Presses volume keys through Relay and checks the volume status it reports.
// Leaves volume and mute as it found them.
let code = CommandLine.arguments[1]
let t = URLSession.shared.webSocketTask(with: URL(string: "ws://127.0.0.1:8766/")!)
t.resume()
func say(_ m: String) async throws { try await t.send(.string(m)) }
func hear() async throws -> String { if case .string(let s) = try await t.receive() { return s }; return "" }
try await say("a \(code)"); _ = try await hear()
try await say("q vol"); let before = try await hear(); print("status before:      \(before)")
try await say("x volup"); print("after volume up:    \(try await hear())")
try await say("x voldown"); print("after volume down:  \(try await hear())")
try await say("x mute"); print("after mute:         \(try await hear())")
try await say("x mute"); print("after unmute:       \(try await hear())")
try await say("x bogus"); try await say("q vol"); let after = try await hear()
print("status after:       \(after)")
print(before == after ? "PASS: volume and mute restored" : "CHECK: final state differs from start")
t.cancel(with: .normalClosure, reason: nil)
