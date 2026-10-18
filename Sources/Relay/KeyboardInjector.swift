import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Types text and presses keys/shortcuts via Core Graphics keyboard events.
/// All calls must come from the same serial queue as InputInjector.
final class KeyboardInjector {
    struct Modifiers: OptionSet {
        let rawValue: Int
        static let control = Modifiers(rawValue: 1 << 0)
        static let option = Modifiers(rawValue: 1 << 1)
        static let shift = Modifiers(rawValue: 1 << 2)
        static let command = Modifiers(rawValue: 1 << 3)

        /// Parses "cmd,shift" style lists; "-" or "" means none.
        init(list: Substring) {
            var m: Modifiers = []
            for name in list.split(separator: ",") {
                switch name {
                case "ctrl": m.insert(.control)
                case "opt": m.insert(.option)
                case "shift": m.insert(.shift)
                case "cmd": m.insert(.command)
                default: break
                }
            }
            self = m
        }

        init(rawValue: Int) { self.rawValue = rawValue }
    }

    /// Pressed in this order, released in reverse — like a person would.
    private static let modifierKeys: [(Modifiers, CGKeyCode, CGEventFlags)] = [
        (.control, CGKeyCode(kVK_Control), .maskControl),
        (.option, CGKeyCode(kVK_Option), .maskAlternate),
        (.shift, CGKeyCode(kVK_Shift), .maskShift),
        (.command, CGKeyCode(kVK_Command), .maskCommand),
    ]

    private static let namedKeys: [String: CGKeyCode] = [
        "return": CGKeyCode(kVK_Return), "tab": CGKeyCode(kVK_Tab), "space": CGKeyCode(kVK_Space),
        "delete": CGKeyCode(kVK_Delete), "fwddelete": CGKeyCode(kVK_ForwardDelete),
        "escape": CGKeyCode(kVK_Escape),
        "left": CGKeyCode(kVK_LeftArrow), "right": CGKeyCode(kVK_RightArrow),
        "up": CGKeyCode(kVK_UpArrow), "down": CGKeyCode(kVK_DownArrow),
        "home": CGKeyCode(kVK_Home), "end": CGKeyCode(kVK_End),
        "pageup": CGKeyCode(kVK_PageUp), "pagedown": CGKeyCode(kVK_PageDown),
    ]

    /// US-ANSI positions, used for shortcuts such as ⌘L. Text itself is typed
    /// as Unicode, so it doesn't depend on the keyboard layout.
    private static let characterKeys: [Character: CGKeyCode] = [
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z,
        "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3, "4": kVK_ANSI_4,
        "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8, "9": kVK_ANSI_9,
        "-": kVK_ANSI_Minus, "=": kVK_ANSI_Equal, "[": kVK_ANSI_LeftBracket,
        "]": kVK_ANSI_RightBracket, "\\": kVK_ANSI_Backslash, ";": kVK_ANSI_Semicolon,
        "'": kVK_ANSI_Quote, ",": kVK_ANSI_Comma, ".": kVK_ANSI_Period, "/": kVK_ANSI_Slash,
        "`": kVK_ANSI_Grave,
    ].mapValues { CGKeyCode($0) }

    /// Keys that real keyboards flag as function/keypad keys; some apps check this.
    private static let functionKeys: Set<CGKeyCode> = [
        CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow), CGKeyCode(kVK_UpArrow),
        CGKeyCode(kVK_DownArrow), CGKeyCode(kVK_Home), CGKeyCode(kVK_End),
        CGKeyCode(kVK_PageUp), CGKeyCode(kVK_PageDown), CGKeyCode(kVK_ForwardDelete),
    ]
    private static let arrowKeys: Set<CGKeyCode> = [
        CGKeyCode(kVK_LeftArrow), CGKeyCode(kVK_RightArrow), CGKeyCode(kVK_UpArrow), CGKeyCode(kVK_DownArrow),
    ]

    private let source = CGEventSource(stateID: .hidSystemState)

    /// Types arbitrary Unicode text. CGEvent carries at most 20 UTF-16 units per
    /// event, so text is chunked on character boundaries.
    func type(_ text: String) {
        var chunk: [UniChar] = []
        for character in text {
            let units = Array(String(character).utf16)
            if chunk.count + units.count > 20 {
                postUnicode(chunk)
                chunk.removeAll()
            }
            chunk.append(contentsOf: units)
        }
        if !chunk.isEmpty { postUnicode(chunk) }
    }

    /// Presses a named key ("return", "left", …) or a single character ("l") with modifiers.
    /// Returns false for unknown keys.
    @discardableResult
    func press(_ name: String, modifiers: Modifiers) -> Bool {
        let code: CGKeyCode
        if let named = KeyboardInjector.namedKeys[name] {
            code = named
        } else if name.count == 1, let c = name.lowercased().first, let mapped = KeyboardInjector.characterKeys[c] {
            code = mapped
        } else {
            return false
        }

        var flags: CGEventFlags = []
        let held = KeyboardInjector.modifierKeys.filter { modifiers.contains($0.0) }
        for (_, key, flag) in held {
            flags.insert(flag)
            postFlagsChanged(key: key, flags: flags)
        }

        var keyFlags = flags
        if KeyboardInjector.functionKeys.contains(code) { keyFlags.insert(.maskSecondaryFn) }
        if KeyboardInjector.arrowKeys.contains(code) { keyFlags.insert(.maskNumericPad) }
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else { continue }
            e.flags = keyFlags
            e.post(tap: .cghidEventTap)
        }

        for (_, key, flag) in held.reversed() {
            flags.remove(flag)
            postFlagsChanged(key: key, flags: flags)
        }
        return true
    }

    private func postUnicode(_ units: [UniChar]) {
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
            e.flags = []
            var buffer = units
            e.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: &buffer)
            e.post(tap: .cghidEventTap)
        }
    }

    private func postFlagsChanged(key: CGKeyCode, flags: CGEventFlags) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}
