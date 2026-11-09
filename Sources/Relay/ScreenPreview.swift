import CoreGraphics
import CoreMedia
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers
import VideoToolbox

/// Live preview of the Mac's screens on the phone, built to cost as little power as possible:
///
/// - **Off unless asked.** Nothing is captured until the phone opens the preview, and it stops
///   the moment the preview closes, the phone locks or switches apps, or the phone disconnects.
///   (While it runs, macOS shows its purple screen-recording indicator in the menu bar.)
/// - **One screen at a time by default.** "Auto" captures only the screen the cursor is on and
///   switches when the cursor moves to another one, so a second display costs nothing extra.
/// - **Only changes are sent.** ScreenCaptureKit reports when the screen didn't change; those
///   frames are skipped, so a still screen costs no encoding and no Wi-Fi.
/// - **Slow unless something happens.** 6 frames per second for a moment after you click,
///   scroll or type; at most 1 per second while you're using Relay; 1 every 3 seconds after
///   30 seconds untouched; and after 3 minutes untouched the preview pauses itself.
/// - **The cursor travels separately.** Frames are captured without the cursor; only its
///   position is sent ("C x y", a few bytes) and the phone draws it on top.
/// - **Small and cheap frames.** macOS scales each frame on the GPU to the size it's shown at on
///   the phone; the JPEG comes from the hardware encoder on a background (efficiency-core) queue.
/// - **Never queues up.** One frame per screen is in flight; the next goes only after the phone
///   says it has shown the last one, so a slow phone or Wi-Fi never piles up work.
final class ScreenPreview: NSObject, SCStreamOutput, SCStreamDelegate {
    enum Mode: Equatable {
        case follow          // the screen the cursor is on
        case all
        case screen(Int)

        /// Protocol value: -2 follow, -1 all, n one screen.
        init(_ n: Int) { self = n == -1 ? .all : n >= 0 ? .screen(n) : .follow }
    }

    static let activeInterval = 1.0 / 6
    static let restInterval = 1.0
    static let idleInterval = 3.0
    static let activeFor: CFAbsoluteTime = 1.5
    static let idleAfter: CFAbsoluteTime = 30
    static let pauseAfter: CFAbsoluteTime = 180
    /// No acknowledgement or ping for this long: the phone has gone (locked, suspended).
    static let ackTimeout: CFAbsoluteTime = 6
    static let maxWidth = 1600
    static let jpegQuality = 0.55

    private final class Screen {
        let index: Int
        let stream: SCStream
        let config: SCStreamConfiguration
        var inFlightSince: CFAbsoluteTime?
        var lastSentAt: CFAbsoluteTime = 0
        var flushScheduled = false
        var latest: CVPixelBuffer?
        init(index: Int, stream: SCStream, config: SCStreamConfiguration) {
            self.index = index
            self.stream = stream
            self.config = config
        }
    }

    private let queue = DispatchQueue(label: "relay.preview", qos: .utility)
    private var screens: [ObjectIdentifier: Screen] = [:]
    private var displays: [(display: SCDisplay, rect: CGRect)] = []
    private var mode = Mode.follow
    private var widthPx = 800
    private var shownIndex = -1
    private var sendText: ((String) -> Void)?
    private var sendData: ((Data) -> Void)?
    private var generation = 0
    /// Our own frame-rate cap: ScreenCaptureKit's minimumFrameInterval isn't honoured while the
    /// cursor moves, so extra frames are dropped here before any encoding or sending.
    private var interval = ScreenPreview.restInterval
    private var activeUntil: CFAbsoluteTime = 0
    private var lastInteraction: CFAbsoluteTime = 0
    private var lastHeard: CFAbsoluteTime = 0
    private var watchdog: DispatchSourceTimer?

    /// Starts (or restarts) the preview. widthPx: how wide each screen is shown on the phone.
    func start(widthPx: Int, mode: Mode, sendText: @escaping (String) -> Void,
               sendData: @escaping (Data) -> Void) {
        queue.async { [self] in
            stopAll()
            generation += 1
            let gen = generation
            self.sendText = sendText
            self.sendData = sendData
            self.mode = mode
            self.widthPx = min(max(widthPx, 200), ScreenPreview.maxWidth)
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: true) { content, error in
                self.queue.async {
                    guard gen == self.generation else { return }
                    if let found = content?.displays, !found.isEmpty {
                        // Left to right, in global screen points (top-left origin).
                        self.displays = found.map { ($0, CGDisplayBounds($0.displayID)) }
                            .sorted { $0.rect.minX < $1.rect.minX }
                        self.begin()
                        return
                    }
                    Log.info("preview: can't capture the screen (\(error?.localizedDescription ?? "no displays"))")
                    // Shows the system prompt the first time; afterwards it's in System Settings.
                    if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
                    sendText("S denied")
                }
            }
        }
    }

    func stop() {
        queue.async { [self] in
            generation += 1
            stopAll()
            sendText = nil
            sendData = nil
        }
    }

    /// The phone has shown the last frame of this screen.
    func ack(_ index: Int) {
        queue.async { [self] in
            guard let screen = screens.values.first(where: { $0.index == index }) else { return }
            screen.inFlightSince = nil
            sendLatestWhenDue(screen)
        }
    }

    /// The phone that owns the preview is still there (it pings every 2 s while open).
    func heard() {
        queue.async { [self] in lastHeard = CFAbsoluteTimeGetCurrent() }
    }

    /// The phone moved the cursor (throttled by the caller).
    func cursor(_ p: CGPoint) {
        queue.async { [self] in
            guard !screens.isEmpty, let sendText else { return }
            lastInteraction = CFAbsoluteTimeGetCurrent()
            sendText("C \(Int(p.x)) \(Int(p.y))")
            follow(p)
            updatePacing()
        }
    }

    /// The phone clicked, scrolled or typed: briefly raise the frame rate to show the result.
    func activity() {
        queue.async { [self] in
            guard !screens.isEmpty else { return }
            let now = CFAbsoluteTimeGetCurrent()
            lastInteraction = now
            activeUntil = now + ScreenPreview.activeFor
            updatePacing()
            queue.asyncAfter(deadline: .now() + ScreenPreview.activeFor + 0.05) { [self] in updatePacing() }
        }
    }

    // MARK: - Capture

    private func begin() {
        let now = CFAbsoluteTimeGetCurrent()
        lastInteraction = now
        lastHeard = now
        activeUntil = 0
        interval = ScreenPreview.restInterval
        switch mode {
        case .follow: shownIndex = displayIndex(at: CGEvent(source: nil)?.location ?? .zero)
        case .all: shownIndex = -1
        case .screen(let n): shownIndex = n < displays.count ? n : -1
        }
        sendLayout()
        startStreams()
        startWatchdog()
    }

    /// "S <x> <y> <w> <h> <shown> <x,y,w,h>…": the whole desktop, which screen is being sent
    /// (-1 = all of them), then each screen's rectangle, all in Mac screen points.
    private func sendLayout() {
        let union = displays.dropFirst().reduce(displays[0].rect) { $0.union($1.rect) }
        let rects = displays.map { "\(Int($0.rect.minX)),\(Int($0.rect.minY)),\(Int($0.rect.width)),\(Int($0.rect.height))" }
        sendText?("S \(Int(union.minX)) \(Int(union.minY)) \(Int(union.width)) \(Int(union.height)) \(shownIndex) "
                  + rects.joined(separator: " "))
    }

    private func startStreams() {
        for (index, entry) in displays.enumerated() where shownIndex == -1 || shownIndex == index {
            let scale = Double(widthPx) / entry.rect.width   // each screen is shown widthPx wide
            let config = SCStreamConfiguration()
            config.width = max(2, Int(entry.rect.width * scale) & ~1)
            config.height = max(2, Int(entry.rect.height * scale) & ~1)
            config.minimumFrameInterval = CMTime(seconds: interval, preferredTimescale: 600)
            config.queueDepth = 3
            config.showsCursor = false               // drawn by the phone from "C x y"
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.captureResolution = .nominal      // never capture Retina pixels we'd throw away
            config.capturesAudio = false
            let filter = SCContentFilter(display: entry.display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: config, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            } catch {
                Log.info("preview: \(error.localizedDescription)")
                continue
            }
            screens[ObjectIdentifier(stream)] = Screen(index: index, stream: stream, config: config)
            stream.startCapture { error in
                if let error { Log.info("preview: capture failed to start (\(error.localizedDescription))") }
            }
        }
        Log.info("preview: capturing \(screens.count) of \(displays.count) screens at \(widthPx) px (\(mode))")
    }

    private func stopStreams() {
        guard !screens.isEmpty else { return }
        for screen in screens.values { screen.stream.stopCapture { _ in } }
        screens.removeAll()
    }

    private func stopAll() {
        watchdog?.cancel()
        watchdog = nil
        if !screens.isEmpty { Log.info("preview: stopped") }
        stopStreams()
    }

    private func displayIndex(at p: CGPoint) -> Int {
        displays.firstIndex { $0.rect.contains(p) } ?? 0
    }

    /// Auto mode: when the cursor lands on another screen, capture that one instead.
    private func follow(_ p: CGPoint) {
        guard mode == .follow, !displays.isEmpty else { return }
        let index = displayIndex(at: p)
        guard index != shownIndex else { return }
        shownIndex = index
        stopStreams()
        sendLayout()
        startStreams()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let screen = screens[ObjectIdentifier(stream)],
              let info = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                          as? [[SCStreamFrameInfo: Any]])?.first,
              let raw = info[.status] as? Int, let status = SCFrameStatus(rawValue: raw),
              status == .complete || status == .started,     // skip "nothing changed" frames
              let pixels = sampleBuffer.imageBuffer else { return }
        screen.latest = pixels   // only the newest frame is ever kept
        sendLatestWhenDue(screen)
    }

    /// Sends the newest frame if the phone is ready and the frame interval has passed;
    /// otherwise makes sure it goes out as soon as it's due, so the last change is never lost.
    private func sendLatestWhenDue(_ screen: Screen) {
        guard screen.latest != nil, screen.inFlightSince == nil else { return }
        let wait = screen.lastSentAt + interval - CFAbsoluteTimeGetCurrent()
        if wait <= 0, let pixels = screen.latest {
            screen.latest = nil
            send(pixels, of: screen)
        } else if !screen.flushScheduled {
            screen.flushScheduled = true
            let gen = generation
            queue.asyncAfter(deadline: .now() + min(max(wait, 0.001), ScreenPreview.idleInterval)) { [self] in
                screen.flushScheduled = false
                if gen == generation { sendLatestWhenDue(screen) }
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [self] in
            Log.info("preview: capture stopped (\(error.localizedDescription))")
            screens.removeValue(forKey: ObjectIdentifier(stream))
        }
    }

    private func send(_ pixels: CVPixelBuffer, of screen: Screen) {
        guard let sendData, let jpeg = ScreenPreview.jpeg(pixels) else { return }
        // The cursor may have moved without Relay (the Mac's own trackpad): send it with each frame.
        if let p = CGEvent(source: nil)?.location { sendText?("C \(Int(p.x)) \(Int(p.y))") }
        var message = Data([UInt8(screen.index)])
        message.append(jpeg)
        screen.inFlightSince = CFAbsoluteTimeGetCurrent()
        screen.lastSentAt = screen.inFlightSince!
        sendData(message)
    }

    private static func jpeg(_ pixels: CVPixelBuffer) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixels, options: nil, imageOut: &image)
        guard let image else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // MARK: - Pacing

    private func updatePacing() {
        let now = CFAbsoluteTimeGetCurrent()
        let wanted = now < activeUntil ? ScreenPreview.activeInterval
            : now - lastInteraction > ScreenPreview.idleAfter ? ScreenPreview.idleInterval
            : ScreenPreview.restInterval
        guard wanted != interval else { return }
        interval = wanted
        for screen in screens.values {
            screen.config.minimumFrameInterval = CMTime(seconds: wanted, preferredTimescale: 600)
            screen.stream.updateConfiguration(screen.config) { _ in }
        }
    }

    private func startWatchdog() {
        watchdog?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 2, repeating: 2, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.check() }
        t.resume()
        watchdog = t
    }

    private func check() {
        let now = CFAbsoluteTimeGetCurrent()
        let unanswered = screens.values.contains { now - ($0.inFlightSince ?? now) > ScreenPreview.ackTimeout }
        if unanswered || now - lastHeard > ScreenPreview.ackTimeout {
            Log.info("preview: phone stopped responding")
            generation += 1
            stopAll()
            return
        }
        if now - lastInteraction > ScreenPreview.pauseAfter {
            Log.info("preview: paused after \(Int(ScreenPreview.pauseAfter)) s untouched")
            generation += 1
            stopAll()
            sendText?("S paused")
            return
        }
        // The cursor may have crossed to another screen using the Mac's own trackpad.
        if mode == .follow, let p = CGEvent(source: nil)?.location { follow(p) }
        updatePacing()
    }
}
