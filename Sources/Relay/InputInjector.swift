import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.pwr_mgt

/// Turns Relay commands into real macOS input via Core Graphics events.
/// Requires the Accessibility permission (System Settings › Privacy & Security).
/// All calls must come from the same serial queue.
final class InputInjector {
    enum Button: Int {
        case left = 0, right = 1

        var cg: CGMouseButton { self == .left ? .left : .right }
        var down: CGEventType { self == .left ? .leftMouseDown : .rightMouseDown }
        var up: CGEventType { self == .left ? .leftMouseUp : .rightMouseUp }
        var dragged: CGEventType { self == .left ? .leftMouseDragged : .rightMouseDragged }
    }

    /// After this long without Relay movement, pick up wherever the physical mouse left the cursor.
    private static let resyncAfter: CFAbsoluteTime = 0.25
    /// Output rate for paced cursor motion (matches a 120 Hz ProMotion display).
    private static let tick: Double = 1.0 / 120

    private let queue: DispatchQueue
    private let source = CGEventSource(stateID: .hidSystemState)
    private var position: CGPoint?
    private var lastMoveAt: CFAbsoluteTime = 0
    private var scrollRemainder = (x: 0.0, y: 0.0)
    private var pressed: Set<Button> = []
    private var lastActivityDeclared: CFAbsoluteTime = 0

    /// AXIsProcessTrusted reflects a grant immediately; CGPreflightPostEventAccess stays
    /// false until the process restarts even though posting already works.
    var hasPermission: Bool { AXIsProcessTrusted() }

    /// Pace cursor output evenly instead of jumping whenever a Wi-Fi packet lands.
    var smoothing = true
    /// Extra pacing delay that bridges a late Wi-Fi packet without the cursor freezing.
    /// 4 ms measured best: unevenness 1.12 → 0.42 vs. unpaced, for ~4 ms of latency.
    var reserve: Double = 0.004

    // Motion pacing state.
    private var pending = (x: 0.0, y: 0.0)
    private var packetInterval = 1.0 / 60
    private var lastPacketAt: CFAbsoluteTime = 0
    private var timer: DispatchSourceTimer?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Moves the cursor by an already-accelerated delta in screen points.
    ///
    /// The phone sends one delta per touch event (60 Hz), and Wi-Fi delivers them
    /// unevenly: late, early, sometimes two at once. Posting each one as it arrives
    /// makes the cursor stutter. Instead, each delta is spread across the display
    /// frames until the next packet is due, so the cursor glides at a steady speed.
    /// Cost: about half a packet interval (~8 ms) of added latency. Nothing is dropped.
    func move(dx: Double, dy: Double) {
        guard smoothing else { apply(dx: dx, dy: dy); return }
        let now = CFAbsoluteTimeGetCurrent()
        let gap = now - lastPacketAt
        if gap < 0.1 {
            packetInterval += (min(max(gap, 0.004), 0.034) - packetInterval) * 0.15
        }
        lastPacketAt = now
        pending.x += dx
        pending.y += dy
        if timer == nil {
            // First packet of a gesture: move immediately, then keep pacing on a timer.
            startTimer()
            step()
        }
    }

    /// Emits the share of pending motion due this frame.
    private func step() {
        let now = CFAbsoluteTimeGetCurrent()
        if pending.x != 0 || pending.y != 0 {
            let nextPacketDue = lastPacketAt + packetInterval + reserve
            let framesLeft = max(1, ((nextPacketDue - now) / InputInjector.tick).rounded(.up))
            var ox = pending.x / framesLeft
            var oy = pending.y / framesLeft
            if framesLeft == 1 || (abs(pending.x - ox) < 0.01 && abs(pending.y - oy) < 0.01) {
                (ox, oy) = (pending.x, pending.y)
            }
            pending.x -= ox
            pending.y -= oy
            apply(dx: ox, dy: oy)
        } else if now - lastPacketAt > 0.1 {
            stopTimer()   // idle: no timer runs while the phone isn't moving the cursor
        }
    }

    /// Delivers any motion still being paced, so clicks and scrolls land where the cursor is shown.
    func flushMotion() {
        guard pending.x != 0 || pending.y != 0 else { return }
        let (dx, dy) = (pending.x, pending.y)
        pending = (0, 0)
        apply(dx: dx, dy: dy)
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + InputInjector.tick, repeating: InputInjector.tick, leeway: .microseconds(500))
        t.setEventHandler { [weak self] in self?.step() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }

    private func apply(dx: Double, dy: Double) {
        // The system cursor location lags just-posted events, so only trust it
        // between bursts of Relay movement (when the physical mouse may have moved).
        let now = CFAbsoluteTimeGetCurrent()
        var p = position ?? currentLocation()
        if now - lastMoveAt > InputInjector.resyncAfter { p = currentLocation() }
        lastMoveAt = now
        p.x += dx
        p.y += dy
        p = Displays.clamp(p)
        position = p

        let type: CGEventType
        let button: CGMouseButton
        if pressed.contains(.left) { (type, button) = (Button.left.dragged, .left) }
        else if pressed.contains(.right) { (type, button) = (Button.right.dragged, .right) }
        else { (type, button) = (.mouseMoved, .left) }

        post(type, at: p, button: button) { e in
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx.rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy.rounded()))
        }
    }

    func click(_ button: Button, count: Int) {
        flushMotion()
        press(button, count: count)
        release(button, count: count)
    }

    func press(_ button: Button, count: Int) {
        flushMotion()
        pressed.insert(button)
        post(button.down, at: cursorLocation(), button: button.cg) { e in
            e.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        }
    }

    func release(_ button: Button, count: Int) {
        flushMotion()
        guard pressed.remove(button) != nil else { return }
        post(button.up, at: cursorLocation(), button: button.cg) { e in
            e.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        }
    }

    /// Scrolls by a pixel delta in wheel convention (positive = content moves down/right).
    /// Fractions are carried over so slow two-finger drags still scroll smoothly.
    func scroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let ix = Int32(scrollRemainder.x.rounded(.towardZero))
        let iy = Int32(scrollRemainder.y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return }
        flushMotion()
        scrollRemainder.x -= Double(ix)
        scrollRemainder.y -= Double(iy)

        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel,
                              wheelCount: 2, wheel1: iy, wheel2: ix, wheel3: 0) else { return }
        e.location = cursorLocation()
        e.post(tap: .cghidEventTap)
        declareActivity()
    }

    /// Find my cursor: jumps to the middle of the screen it's on, then shakes it so macOS
    /// briefly shows it large ("Shake mouse pointer to locate", on by default).
    func locate() {
        flushMotion()
        let rect = Displays.containing(cursorLocation())
        let center = CGPoint(x: rect.midX, y: rect.midY)
        // Quick left-right strokes of shrinking width, ending on the centre.
        let strokes = 14
        for i in 0...strokes {
            let amplitude = i == strokes ? 0 : 160 * (1 - Double(i) / Double(strokes + 4))
            let x = center.x + (i % 2 == 0 ? amplitude : -amplitude)
            queue.asyncAfter(deadline: .now() + Double(i) * 0.016) { [self] in
                moveTo(CGPoint(x: x, y: center.y))
            }
        }
    }

    /// Where Relay last put the cursor (or the system's cursor location).
    var location: CGPoint { cursorLocation() }

    /// Puts the cursor at a point in global screen coordinates (tap on the screen preview).
    func moveTo(_ target: CGPoint) {
        pending = (0, 0)
        let from = cursorLocation()
        let p = Displays.clamp(target)
        position = p
        lastMoveAt = CFAbsoluteTimeGetCurrent()
        let type: CGEventType = pressed.contains(.left) ? .leftMouseDragged : .mouseMoved
        post(type, at: p, button: .left) { e in
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - from.x).rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - from.y).rounded()))
        }
    }

    /// Called when a controller disconnects so no button is left stuck down.
    func releaseAll() {
        flushMotion()
        stopTimer()
        for button in pressed { release(button, count: 1) }
    }

    /// Where the cursor is (or is about to be). The system location lags events
    /// posted in the last frame, so trust our own position during Relay movement.
    private func cursorLocation() -> CGPoint {
        if let position, CFAbsoluteTimeGetCurrent() - lastMoveAt < InputInjector.resyncAfter { return position }
        return currentLocation()
    }

    private func currentLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? position ?? .zero
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton,
                      configure: (CGEvent) -> Void = { _ in }) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type,
                              mouseCursorPosition: p, mouseButton: button) else { return }
        configure(e)
        e.post(tap: .cghidEventTap)
        declareActivity()
    }

    /// Wakes a sleeping display on the first input. Injected events already count as
    /// user activity for the idle timer, so nothing is held while the display is on,
    /// and the wake assertion is released right away so the Mac sleeps on its normal schedule.
    private func declareActivity() {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastActivityDeclared > 1 else { return }
        lastActivityDeclared = now
        guard Displays.anyAsleep() else { return }
        var id: IOPMAssertionID = 0
        if IOPMAssertionDeclareUserActivity("Relay wake display" as CFString, kIOPMUserActiveLocal, &id) == kIOReturnSuccess {
            queue.asyncAfter(deadline: .now() + 2) { IOPMAssertionRelease(id) }
        }
    }
}

/// Keeps the cursor on a real display (built-in, TV, or both).
enum Displays {
    private static var cached: [CGRect] = []
    private static var cachedAt: CFAbsoluteTime = 0

    static func anyAsleep() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        return ids.prefix(Int(count)).contains { CGDisplayIsAsleep($0) != 0 }
    }

    /// The display under p, or the main display.
    static func containing(_ p: CGPoint) -> CGRect {
        bounds().first { $0.contains(p) } ?? CGDisplayBounds(CGMainDisplayID())
    }

    static func clamp(_ p: CGPoint) -> CGPoint {
        let rects = bounds()
        if rects.isEmpty || rects.contains(where: { $0.contains(p) }) { return p }
        var best = p
        var bestDistance = Double.infinity
        for r in rects {
            let c = CGPoint(x: min(max(p.x, r.minX), r.maxX - 1), y: min(max(p.y, r.minY), r.maxY - 1))
            let d = hypot(c.x - p.x, c.y - p.y)
            if d < bestDistance { bestDistance = d; best = c }
        }
        return best
    }

    private static func bounds() -> [CGRect] {
        let now = CFAbsoluteTimeGetCurrent()
        if now - cachedAt < 1, !cached.isEmpty { return cached }
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return cached }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return cached }
        cached = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        cachedAt = now
        return cached
    }
}
