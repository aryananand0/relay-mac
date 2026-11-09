import Foundation
// mode "idle": connected phone sitting open (pings every 2 s). mode "move": finger moving at 60 Hz.
let code = CommandLine.arguments[1], mode = CommandLine.arguments[2], seconds = Double(CommandLine.arguments[3])!
let t = RelayClient()
t.resume()
try await t.send(.string("a \(code)")); _ = try await t.receive()
let end = Date().addingTimeInterval(seconds)
var i = 0
while Date() < end {
    if mode == "move" {
        let dx = (i / 60) % 2 == 0 ? 4 : -4      // back and forth so the cursor stays on screen
        try await t.send(.string("m \(dx) 0")); i += 1
        try await Task.sleep(nanoseconds: 16_666_667)
    } else {
        try await t.send(.string("p 1")); _ = try await t.receive()
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }
}
t.cancel(with: .normalClosure, reason: nil)
