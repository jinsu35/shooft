import CoreGraphics
import Foundation

/// A modifier the pedal applies to whatever the keyboard types while the foot
/// is down. The pedal itself is programmed to send an F-key no Mac keyboard
/// has, and the engine turns that into the modifier flag.
enum FootModifier: String, CaseIterable, Identifiable {
    case shift, control, option, command

    var id: String { rawValue }

    /// HID usage written into the pedal.
    var usage: UInt8 {
        switch self {
        case .shift: return 0x68  // F13
        case .control: return 0x69  // F14
        case .option: return 0x6A  // F15
        case .command: return 0x6B  // F16
        }
    }

    /// macOS virtual keycode the pedal's key arrives as.
    var keycode: Int64 {
        switch self {
        case .shift: return 105
        case .control: return 107
        case .option: return 113
        case .command: return 106
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .shift: return .maskShift
        case .control: return .maskControl
        case .option: return .maskAlternate
        case .command: return .maskCommand
        }
    }

    var label: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        }
    }

    static func from(usage: UInt8) -> FootModifier? {
        allCases.first { $0.usage == usage }
    }

    static func from(keycode: Int64) -> FootModifier? {
        allCases.first { $0.keycode == keycode }
    }

    /// The modifier a Mac keyboard's own modifier key stands for (left/right).
    static func from(modifierKeycode code: Int) -> FootModifier? {
        switch code {
        case 56, 60: return .shift
        case 59, 62: return .control
        case 58, 61: return .option
        case 54, 55: return .command
        default: return nil
        }
    }
}

/// A plain key the pedal can be set to type by itself. `keycode` is the macOS
/// virtual keycode the same key has on a Mac keyboard, used when the user
/// records a key by pressing it.
struct PlainKey: Identifiable, Hashable {
    let id: String
    let label: String
    let usage: UInt8
    let keycode: Int

    static let all: [PlainKey] = {
        var keys: [PlainKey] = [
            PlainKey(id: "none", label: "없음", usage: 0, keycode: -1),
            PlainKey(id: "enter", label: "Enter ↩", usage: 0x28, keycode: 0x24),
            PlainKey(id: "space", label: "Space", usage: 0x2C, keycode: 0x31),
            PlainKey(id: "tab", label: "Tab ⇥", usage: 0x2B, keycode: 0x30),
            PlainKey(id: "esc", label: "Escape ⎋", usage: 0x29, keycode: 0x35),
            PlainKey(id: "backspace", label: "Delete ⌫", usage: 0x2A, keycode: 0x33),
            PlainKey(id: "fwddelete", label: "Forward Delete ⌦", usage: 0x4C, keycode: 0x75),
            PlainKey(id: "up", label: "↑", usage: 0x52, keycode: 0x7E),
            PlainKey(id: "down", label: "↓", usage: 0x51, keycode: 0x7D),
            PlainKey(id: "left", label: "←", usage: 0x50, keycode: 0x7B),
            PlainKey(id: "right", label: "→", usage: 0x4F, keycode: 0x7C),
            PlainKey(id: "pageup", label: "Page Up", usage: 0x4B, keycode: 0x74),
            PlainKey(id: "pagedown", label: "Page Down", usage: 0x4E, keycode: 0x79),
            PlainKey(id: "home", label: "Home", usage: 0x4A, keycode: 0x73),
            PlainKey(id: "end", label: "End", usage: 0x4D, keycode: 0x77),
        ]
        // Letters: (mac keycode, HID usage) in usage order a…z.
        let letterCodes = [0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E,
                           0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06]
        for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
            keys.append(PlainKey(id: String(c), label: String(c).uppercased(), usage: UInt8(4 + i), keycode: letterCodes[i]))
        }
        let digitCodes = [0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19, 0x1D]
        for (i, c) in "1234567890".enumerated() {
            keys.append(PlainKey(id: String(c), label: String(c), usage: UInt8(30 + i), keycode: digitCodes[i]))
        }
        let punct: [(String, UInt8, Int)] = [
            ("-", 0x2D, 0x1B), ("=", 0x2E, 0x18), ("[", 0x2F, 0x21), ("]", 0x30, 0x1E), ("\\", 0x31, 0x2A),
            (";", 0x33, 0x29), ("'", 0x34, 0x27), ("`", 0x35, 0x32), (",", 0x36, 0x2B), (".", 0x37, 0x2F), ("/", 0x38, 0x2C),
        ]
        for (c, usage, code) in punct {
            keys.append(PlainKey(id: "p\(usage)", label: c, usage: usage, keycode: code))
        }
        let fCodes = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F]
        for n in 1...12 {
            keys.append(PlainKey(id: "f\(n)", label: "F\(n)", usage: UInt8(0x3A + n - 1), keycode: fCodes[n - 1]))
        }
        // F13–F16 are reserved for the foot modifiers.
        for (n, usage, code) in [(17, 0x6C, 0x40), (18, 0x6D, 0x4F), (19, 0x6E, 0x50), (20, 0x6F, 0x5A)] {
            keys.append(PlainKey(id: "f\(n)", label: "F\(n)", usage: UInt8(usage), keycode: code))
        }
        let keypad: [(String, UInt8, Int)] = [
            ("0", 0x62, 0x52), ("1", 0x59, 0x53), ("2", 0x5A, 0x54), ("3", 0x5B, 0x55), ("4", 0x5C, 0x56),
            ("5", 0x5D, 0x57), ("6", 0x5E, 0x58), ("7", 0x5F, 0x59), ("8", 0x60, 0x5B), ("9", 0x61, 0x5C),
            (".", 0x63, 0x41), ("+", 0x57, 0x45), ("-", 0x56, 0x4E), ("*", 0x55, 0x43), ("/", 0x54, 0x4B),
            ("=", 0x67, 0x51), ("Enter", 0x58, 0x4C), ("Clear", 0x53, 0x47),
        ]
        for (c, usage, code) in keypad {
            keys.append(PlainKey(id: "kp\(usage)", label: "Keypad \(c)", usage: usage, keycode: code))
        }
        return keys
    }()

    static func from(usage: UInt8) -> PlainKey? {
        all.first { $0.usage == usage }
    }

    static func from(keycode: Int) -> PlainKey? {
        keycode < 0 ? nil : all.first { $0.keycode == keycode }
    }
}

/// Modifier bits in the pedal's own protocol, held together with a plain key.
struct PedalModifiers: OptionSet, Hashable {
    let rawValue: UInt8
    static let control = PedalModifiers(rawValue: 0x01)
    static let shift = PedalModifiers(rawValue: 0x02)
    static let option = PedalModifiers(rawValue: 0x04)
    static let command = PedalModifiers(rawValue: 0x08)  // "win" on PC
}

/// What one pedal is set to, as stored in the pedal.
enum PedalSetting: Equatable {
    case foot(FootModifier)
    case key(usage: UInt8, modifiers: PedalModifiers)
    /// Something this app does not edit (mouse action, typed string).
    case other(String)

    var usage: UInt8 {
        switch self {
        case .foot(let m): return m.usage
        case .key(let usage, _): return usage
        case .other: return 0
        }
    }

    var modifiers: PedalModifiers {
        if case .key(_, let m) = self { return m }
        return []
    }

    var summary: String {
        switch self {
        case .foot(let m): return "\(m.label) (밟는 동안)"
        case .key(let usage, let mods):
            var parts: [String] = []
            if mods.contains(.control) { parts.append("⌃") }
            if mods.contains(.option) { parts.append("⌥") }
            if mods.contains(.shift) { parts.append("⇧") }
            if mods.contains(.command) { parts.append("⌘") }
            parts.append(PlainKey.from(usage: usage)?.label ?? String(format: "0x%02X", usage))
            return parts.joined()
        case .other(let text): return text
        }
    }

    static let factoryDefault: [PedalSetting] = [
        .key(usage: 0x04, modifiers: []), .key(usage: 0x05, modifiers: []), .key(usage: 0x06, modifiers: []),
    ]
    static let allShift: [PedalSetting] = [.foot(.shift), .foot(.shift), .foot(.shift)]
}
