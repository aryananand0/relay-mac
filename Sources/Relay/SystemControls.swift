import AppKit
import CoreAudio
import Foundation

/// Media keys, output volume status, and display sleep.
enum SystemControls {
    /// Hardware media key codes (NX_KEYTYPE_* in IOKit/hidsystem/ev_keymap.h).
    private static let mediaKeys: [String: Int32] = [
        "volup": 0, "voldown": 1, "mute": 7,
        "play": 16, "next": 17, "prev": 18,
    ]

    static func isVolumeKey(_ name: String) -> Bool { ["volup", "voldown", "mute"].contains(name) }

    /// Presses a media key exactly like the keyboard's F-row keys, so macOS routes it to
    /// whatever is playing (Safari/Chrome videos, Music, Spotify) and shows the volume HUD.
    @discardableResult
    static func pressMediaKey(_ name: String) -> Bool {
        guard let code = mediaKeys[name] else { return false }
        for down in [true, false] {
            let flags: Int = down ? 0xA00 : 0xB00
            let data1 = (Int(code) << 16) | ((down ? 0xA : 0xB) << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(flags)),
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                subtype: 8, data1: data1, data2: -1) else { continue }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        return true
    }

    /// Turns the displays off (like hot-corner "Put Display to Sleep"). The first touch on
    /// the phone wakes them again. The Mac itself keeps running.
    static func sleepDisplays() {
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        try? pmset.run()
    }

    struct VolumeStatus {
        /// 0–100, or nil when the output device's volume can't be changed from the Mac
        /// (common for TVs over HDMI).
        let level: Int?
        let muted: Bool
        let deviceName: String

        /// "v <level|-> <muted 0|1> <device name>"
        var message: String {
            "v \(level.map(String.init) ?? "-") \(muted ? 1 : 0) \(deviceName)"
        }
    }

    static func volumeStatus() -> VolumeStatus {
        guard let device = defaultOutputDevice() else { return VolumeStatus(level: nil, muted: false, deviceName: "No output") }
        let name = stringProperty(device, kAudioObjectPropertyName) ?? "Output"

        // Some devices expose one master volume, others only per-channel volumes.
        var level: Float32?
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [AudioObjectPropertyElement] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                                     mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr {
                level = value
                break
            }
        }

        var muted: UInt32 = 0
        var muteAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                     mScope: kAudioDevicePropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &muteAddress) {
            AudioObjectGetPropertyData(device, &muteAddress, 0, nil, &size, &muted)
        }
        return VolumeStatus(level: level.map { Int(($0 * 100).rounded()) }, muted: muted != 0, deviceName: name)
    }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return nil }
        return device
    }

    private static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }
}
