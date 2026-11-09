import Foundation
import CoreGraphics
// Sends scroll commands to Relay and records the scroll events macOS actually sees
// with a listen-only event tap. Net scroll is zero (down then back up).
final class Box { var dy: Int64 = 0; var dx: Int64 = 0; var events = 0; var pixel = 0 }
let box = Box()
let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: mask, callback: { _, _, e, ref in
        let b = Unmanaged<Box>.fromOpaque(ref!).takeUnretainedValue()
        b.events += 1
        b.dy += e.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)
        b.dx += e.getIntegerValueField(.scrollWheelEventPointDeltaAxis2)
        if e.getIntegerValueField(.scrollWheelEventIsContinuous) == 1 { b.pixel += 1 }
        return Unmanaged.passUnretained(e)
    }, userInfo: Unmanaged.passUnretained(box).toOpaque()) else { print("could not create event tap (needs Input Monitoring?)"); exit(2) }
let src = CFMachPortCreateRunLoopSource(nil, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)

let code = CommandLine.arguments[1]
let t = RelayClient()
t.resume()
Task {
    try await t.send(.string("a \(code)"))
    _ = try await t.receive()
    // 20 slow fractional steps (0.5 px each = 10 px total, tests remainder carry), then 20 x 2px, then back up 30 + sideways test.
    for _ in 0..<20 { try await t.send(.string("s 0 0.5")); try await Task.sleep(nanoseconds: 8_000_000) }
    for _ in 0..<10 { try await t.send(.string("s 0 2")); try await Task.sleep(nanoseconds: 8_000_000) }
    for _ in 0..<10 { try await t.send(.string("s 1.5 0")); try await Task.sleep(nanoseconds: 8_000_000) }
    try await t.send(.string("s -15 -30"))
    try await Task.sleep(nanoseconds: 400_000_000)
    print("scroll events seen: \(box.events) (continuous/pixel: \(box.pixel))")
    print("total dy=\(box.dy) dx=\(box.dx)  (expected net 0, 0)")
    t.cancel(with: .normalClosure, reason: nil)
    exit(0)
}
CFRunLoopRun()
