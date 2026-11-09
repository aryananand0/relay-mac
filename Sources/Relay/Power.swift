import Foundation
import IOKit.pwr_mgt

/// Keep Mac awake and the sleep timer. All methods run on the control queue.
///
/// - Keep awake: holds a "prevent display sleep" assertion for a while or until turned
///   off, so the Mac and the TV stay on during a long film with no input.
/// - Sleep timer: also keeps the Mac awake until it ends, then pauses whatever is
///   playing and puts the Mac to sleep.
///
/// Timers use wall-clock deadlines. If the Mac slept anyway (lid closed), a deadline that
/// passed long ago is dropped on wake instead of putting the Mac straight back to sleep.
final class Power {
    private static let staleAfter: TimeInterval = 120

    private let queue: DispatchQueue
    /// .distantFuture means "until turned off".
    private(set) var awakeUntil: Date?
    private(set) var sleepAt: Date?
    private var awakeTimer: DispatchSourceTimer?
    private var sleepTimer: DispatchSourceTimer?
    private var assertion: IOPMAssertionID = 0
    /// Testing: log instead of actually sleeping the Mac ("o dryrun 1").
    var dryRun = false
    /// Called on the control queue after any change.
    var onChange: (() -> Void)?

    init(queue: DispatchQueue) { self.queue = queue }

    /// minutes: nil = off, 0 = until turned off, otherwise for that long.
    func keepAwake(minutes: Double?) {
        awakeTimer?.cancel()
        awakeTimer = nil
        if let minutes {
            if minutes == 0 {
                awakeUntil = .distantFuture
            } else {
                let deadline = Date().addingTimeInterval(minutes * 60)
                awakeUntil = deadline
                awakeTimer = timer(at: deadline) { [weak self] late in
                    guard let self else { return }
                    Log.info("power: keep awake ended\(late ? " (Mac was asleep)" : "")")
                    self.awakeUntil = nil
                    self.awakeTimer = nil
                    self.changed()
                }
            }
            Log.info("power: keep awake \(minutes == 0 ? "until turned off" : "for \(Int(minutes)) min")")
        } else {
            awakeUntil = nil
            Log.info("power: keep awake off")
        }
        changed()
    }

    /// minutes: nil = cancel.
    func sleepTimer(minutes: Double?) {
        sleepTimer?.cancel()
        sleepTimer = nil
        sleepAt = nil
        if let minutes, minutes > 0 {
            let deadline = Date().addingTimeInterval(minutes * 60)
            sleepAt = deadline
            sleepTimer = timer(at: deadline) { [weak self] late in
                guard let self else { return }
                self.sleepAt = nil
                self.sleepTimer = nil
                if late {
                    Log.info("power: sleep timer dropped (Mac was already asleep)")
                    self.changed()
                } else {
                    self.timerEnded()
                }
            }
            Log.info("power: sleep timer \(minutes) min")
        } else {
            Log.info("power: sleep timer off")
        }
        changed()
    }

    /// "W <awake> <sleep>": awake is 0 (off), -1 (until turned off) or seconds left;
    /// sleep is 0 (off) or seconds left.
    var message: String {
        let awake: Int
        switch awakeUntil {
        case nil: awake = 0
        case .distantFuture?: awake = -1
        case let date?: awake = max(1, Int(date.timeIntervalSinceNow.rounded(.up)))
        }
        let sleep = sleepAt.map { max(1, Int($0.timeIntervalSinceNow.rounded(.up))) } ?? 0
        return "W \(awake) \(sleep)"
    }

    /// One line for the menu bar, or nil when nothing is active.
    var summary: String? {
        let time = DateFormatter()
        time.timeStyle = .short
        if let sleepAt { return "Sleep timer: Mac sleeps at \(time.string(from: sleepAt))" }
        switch awakeUntil {
        case nil: return nil
        case .distantFuture?: return "Keeping Mac awake"
        case let date?: return "Keeping Mac awake until \(time.string(from: date))"
        }
    }

    func cancelAll() {
        sleepTimer(minutes: nil)
        keepAwake(minutes: nil)
    }

    private func timerEnded() {
        awakeTimer?.cancel()
        awakeTimer = nil
        awakeUntil = nil
        changed()   // releases the assertion before sleeping
        let playing = SystemControls.isAudioPlaying()
        Log.info("power: sleep timer ended (audio playing: \(playing))")
        // Pause first so the film doesn't carry on when the Mac wakes. There's no
        // pause-only media key, so play/pause is pressed only if sound is playing.
        if playing && !dryRun { SystemControls.pressMediaKey("play") }
        queue.asyncAfter(deadline: .now() + (playing ? 1.5 : 0.2)) { [self] in
            if dryRun { Log.info("power: dry run, not sleeping"); return }
            SystemControls.sleepMac()
        }
    }

    private func changed() {
        let wanted = awakeUntil != nil || sleepAt != nil
        if wanted, assertion == 0 {
            var id: IOPMAssertionID = 0
            if IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                           IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                           "Relay: keeping the Mac awake" as CFString, &id) == kIOReturnSuccess {
                assertion = id
            }
        } else if !wanted, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
        onChange?()
    }

    private func timer(at deadline: Date, fire: @escaping (_ late: Bool) -> Void) -> DispatchSourceTimer {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(wallDeadline: DispatchWallTime(timespec: timespec(
            tv_sec: Int(deadline.timeIntervalSince1970),
            tv_nsec: Int(deadline.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) * 1e9))),
            leeway: .seconds(1))
        t.setEventHandler { fire(Date().timeIntervalSince(deadline) > Power.staleAfter) }
        t.resume()
        return t
    }
}
