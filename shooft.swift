// shooft — foot-pedal Shift for macOS (prototype)
//
// Core question this answers: on macOS, modifier state is tracked per keyboard,
// so Shift coming from a pedal does not capitalise letters typed on the built-in
// keyboard. Karabiner-Elements solves this by re-emitting everything through one
// virtual keyboard. This prototype tries the lighter approach instead: an active
// CGEventTap that *modifies the existing keystroke's flags* rather than posting
// new events. If that works, the shipping app needs only Accessibility, not a
// DriverKit driver.
//
// Build:  swiftc -O shooft.swift -o shooft
// Usage:  ./shooft pick            # press the pedal/key, learn its keycode
//         ./shooft run --keycode 105
//         ./shooft list            # list HID keyboard-ish devices

import ApplicationServices
import CoreGraphics
import Foundation
import IOKit.hid

// MARK: - Keycodes

/// Device-dependent modifier bits from <IOKit/hidsystem/IOLLEvent.h>. A
/// flagsChanged event only says "some modifier changed", so to tell press from
/// release for a specific physical modifier key we test its own bit.
let deviceMaskForKeycode: [Int64: UInt64] = [
    56: 0x0000_0002,  // left shift
    60: 0x0000_0004,  // right shift
    59: 0x0000_0001,  // left control
    62: 0x0000_2000,  // right control
    58: 0x0000_0020,  // left option
    61: 0x0000_0040,  // right option
    55: 0x0000_0008,  // left command
    54: 0x0000_0010,  // right command
]

let keycodeNames: [Int64: String] = [
    105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
    56: "Left Shift", 60: "Right Shift", 59: "Left Control", 62: "Right Control",
    58: "Left Option", 61: "Right Option", 55: "Left Command", 54: "Right Command",
    57: "Caps Lock", 53: "Escape", 49: "Space",
    0: "a", 11: "b", 8: "c", 2: "d", 14: "e", 3: "f", 5: "g", 4: "h", 34: "i", 38: "j", 40: "k", 37: "l",
    46: "m", 45: "n", 31: "o", 35: "p", 12: "q", 15: "r", 1: "s", 17: "t", 32: "u", 9: "v", 13: "w",
    7: "x", 16: "y", 6: "z",
]

func name(for keycode: Int64) -> String {
    keycodeNames[keycode] ?? "keycode \(keycode)"
}

/// USB HID keyboard-page usage → macOS virtual keycode, for the keys a pedal is
/// likely to be configured to send. Used to recognise the pedal's own
/// keystrokes in the event tap when the device could not be seized.
let keycodeForUsage: [UInt32: Int64] = {
    var table: [UInt32: Int64] = [:]
    // a–z (usage 4…29)
    let letters: [Int64] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
    for (i, code) in letters.enumerated() { table[UInt32(4 + i)] = code }
    // 1–9, 0 (usage 30…39)
    let digits: [Int64] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
    for (i, code) in digits.enumerated() { table[UInt32(30 + i)] = code }
    let misc: [UInt32: Int64] = [
        40: 36, 41: 53, 42: 51, 43: 48, 44: 49, 45: 27, 46: 24, 47: 33, 48: 30, 49: 42,
        50: 42, 51: 41, 52: 39, 53: 50, 54: 43, 55: 47, 56: 44, 57: 57,
        // F1–F12 (usage 58…69)
        58: 122, 59: 120, 60: 99, 61: 118, 62: 96, 63: 97, 64: 98, 65: 100, 66: 101, 67: 109, 68: 103, 69: 111,
        70: 105, 71: 107, 72: 113, 73: 114, 74: 115, 75: 116, 76: 117, 77: 119, 78: 121,
        79: 124, 80: 123, 81: 125, 82: 126, 83: 71,
        // keypad
        84: 75, 85: 67, 86: 78, 87: 69, 88: 76, 89: 83, 90: 84, 91: 85, 92: 86, 93: 87, 94: 88, 95: 89,
        96: 91, 97: 92, 98: 82, 99: 65,
        // F13–F20 (usage 104…111)
        104: 105, 105: 107, 106: 113, 107: 106, 108: 64, 109: 79, 110: 80, 111: 90,
        // modifiers (usage 224…231)
        224: 59, 225: 56, 226: 58, 227: 55, 228: 62, 229: 60, 230: 61, 231: 54,
    ]
    table.merge(misc) { a, _ in a }
    return table
}()

// MARK: - Watching the pedal as a device

/// Watches one HID device directly, so we know the pedal is down no matter which
/// key it is configured to send. This is what lets the shipping app skip the
/// "configure your pedal in a Windows tool first" step every rival product needs.
///
/// Opened with `seize` the device is taken over entirely: its keystrokes never
/// reach macOS, so the pedal cannot type letters and nothing has to be swallowed
/// afterwards. Measured 2026-09-27: seizing a *keyboard* interface returns
/// kIOReturnNotPrivileged unless the process runs as root, even with Input
/// Monitoring granted. So a normal app opens the pedal shared (no seize) and
/// swallows its keystrokes in the event tap instead — see PedalShift.
///
/// `onChange` receives the set of keyboard usages currently held on the device.
final class DeviceTrigger {
    private let vendor: Int
    private let product: Int
    private let seize: Bool
    private let onChange: (Set<UInt32>) -> Void

    private var manager: IOHIDManager?
    private var keysDown = Set<UInt32>()

    init(vendor: Int, product: Int, seize: Bool, onChange: @escaping (Set<UInt32>) -> Void) {
        self.vendor = vendor
        self.product = product
        self.seize = seize
        self.onChange = onChange
    }

    /// Returns kIOReturnSuccess, or the IOKit error from opening the device
    /// (usually kIOReturnNotPermitted: missing Input Monitoring permission, or
    /// kIOReturnExclusiveAccess: another process already seized it).
    func start() -> IOReturn {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager

        IOHIDManagerSetDeviceMatching(
            manager,
            [kIOHIDVendorIDKey: vendor, kIOHIDProductIDKey: product] as CFDictionary)

        let callback: IOHIDValueCallback = { context, _, _, value in
            guard let context else { return }
            Unmanaged<DeviceTrigger>.fromOpaque(context).takeUnretainedValue().handle(value)
        }
        IOHIDManagerRegisterInputValueCallback(
            manager, callback, Unmanaged.passUnretained(self).toOpaque())
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

        let options = seize ? IOOptionBits(kIOHIDOptionsTypeSeizeDevice) : IOOptionBits(kIOHIDOptionsTypeNone)
        return IOHIDManagerOpen(manager, options)
    }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad) else { return }
        let usage = IOHIDElementGetUsage(element)
        guard usage >= 4 else { return }  // 0-3 are reserved / roll-over errors
        // The keyboard interface also exposes raw array slots (usage 0xFFFFFFFF
        // whose *value* is the usage). The per-usage elements carry the same
        // information, so ignore the raw slots.
        guard usage != 0xFFFF_FFFF else { return }

        if IOHIDValueGetIntegerValue(value) != 0 {
            keysDown.insert(usage)
        } else {
            keysDown.remove(usage)
        }
        // Any pedal of the three counts, so a foot anywhere on the unit works.
        onChange(keysDown)
    }
}

// MARK: - The tap

final class PedalShift {
    /// nil when the trigger comes from a watched device rather than a keycode.
    private let triggerKeycode: Int64?
    private let verbose: Bool
    /// Safety valve: if the trigger is held this long with no typing, stop
    /// applying Shift. Guards against resting a foot on the pedal and against a
    /// missed key-up leaving Shift stuck on. 0 disables it.
    private let maxHold: Double

    private var triggerDown = false
    /// Device mode without seize: the pedal's own keystrokes still reach macOS
    /// and must be dropped in the tap, but the same letter typed on the real
    /// keyboard must not be. The HID report arrives a few ms before the
    /// keystroke, so: a keyDown that follows a HID press within `pressWindow`
    /// is the pedal's, and so are its auto-repeats and its keyUp. Anything
    /// later for that keycode is the keyboard's.
    private var pedalKeycodes = Set<Int64>()  // held on the device right now
    private var pedalPressedAt: [Int64: CFAbsoluteTime] = [:]  // keyDown expected
    private var pedalOwned = Set<Int64>()  // we swallowed the keyDown
    /// kCGKeyboardEventKeyboardType of the pedal's own keystrokes, learned from
    /// the first one. macOS merges key state per keycode across devices: while
    /// the pedal holds `a`, the keyboard's `a` arrives flagged as an auto-repeat
    /// and its keyUp is dropped. The keyboard type is what still tells the two
    /// apart (measured: pedal 40, MacBook keyboard 91).
    private var pedalKeyboardType: Int64?
    private var pedalReleasedAt: [Int64: CFAbsoluteTime] = [:]  // keyUp expected
    private let pressWindow: CFAbsoluteTime = 0.15
    private let releaseGrace: CFAbsoluteTime = 0.5
    private var triggerDownAt: CFAbsoluteTime = 0
    private var lastTypedAt: CFAbsoluteTime = 0
    private var shiftedKeys = 0
    private var tap: CFMachPort?

    /// Set when the trigger is a device; kept alive for the lifetime of the run.
    private var device: DeviceTrigger?

    init(triggerKeycode: Int64?, maxHold: Double, verbose: Bool) {
        self.triggerKeycode = triggerKeycode
        self.maxHold = maxHold
        self.verbose = verbose
    }

    func watch(vendor: Int, product: Int, seize: Bool) -> IOReturn {
        let device = DeviceTrigger(vendor: vendor, product: product, seize: seize) {
            [weak self] usages in
            guard let self else { return }
            if !seize { self.pedalKeysChanged(usages) }
            self.setTrigger(down: !usages.isEmpty)
        }
        self.device = device
        return device.start()
    }

    func run() -> Never {
        requireAccessibility()

        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<PedalShift>.fromOpaque(refcon).takeUnretainedValue()
            return me.handle(type: type, event: event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,  // active tap: we may modify or drop events
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            fail(
                """
                Could not create the event tap.
                Grant Accessibility to the app running this binary:
                System Settings > Privacy & Security > Accessibility
                (that is Terminal/iTerm, not ./shooft itself)
                """)
        }
        self.tap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        print("shooft running.")
        if let triggerKeycode {
            print("  trigger: \(name(for: triggerKeycode)) — hold it and type a letter")
        } else {
            print("  trigger: the pedal device — step on it and type a letter")
        }
        if maxHold > 0 {
            print("  auto-release: Shift stops after \(maxHold)s of holding without typing")
        }
        print("  Ctrl+C to quit\n")

        CFRunLoopRun()
        exit(0)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables a tap that blocks for too long; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        if type != .flagsChanged,
            isPedalKeystroke(
                keycode: keycode, down: type == .keyDown,
                repeating: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
                keyboardType: event.getIntegerValueField(.keyboardEventKeyboardType))
        {
            return nil  // the pedal's own key, reaching macOS because we could not seize it
        }

        if let triggerKeycode, keycode == triggerKeycode {
            if let bit = deviceMaskForKeycode[triggerKeycode] {
                // The trigger is itself a modifier key: read its own bit.
                if type == .flagsChanged {
                    setTrigger(down: UInt64(event.flags.rawValue) & bit != 0)
                }
            } else if type == .keyDown {
                setTrigger(down: true)
            } else if type == .keyUp {
                setTrigger(down: false)
            }
            return nil  // swallow it, so the pedal never types anything itself
        }

        guard triggerDown, type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }

        if maxHold > 0 {
            let idleSince = max(triggerDownAt, lastTypedAt)
            if CFAbsoluteTimeGetCurrent() - idleSince > maxHold {
                if verbose { log("auto-release: held too long without typing, Shift not applied") }
                return Unmanaged.passUnretained(event)
            }
        }

        // The whole experiment: add Shift to a keystroke that is already in
        // flight, instead of synthesising a new one.
        event.flags.insert(.maskShift)

        if type == .keyDown {
            lastTypedAt = CFAbsoluteTimeGetCurrent()
            shiftedKeys += 1
            if verbose { log("shift+\(name(for: keycode))") }
        }
        return Unmanaged.passUnretained(event)
    }

    private func pedalKeysChanged(_ usages: Set<UInt32>) {
        let now = CFAbsoluteTimeGetCurrent()
        let keycodes = Set(usages.compactMap { keycodeForUsage[$0] })
        for pressed in keycodes.subtracting(pedalKeycodes) {
            pedalPressedAt[pressed] = now
        }
        for released in pedalKeycodes.subtracting(keycodes) {
            pedalPressedAt[released] = nil
            if pedalOwned.remove(released) != nil { pedalReleasedAt[released] = now }
        }
        if verbose {
            for unknown in usages where keycodeForUsage[unknown] == nil {
                log("pedal sends HID usage \(unknown), which I cannot map to a keycode; it may type")
            }
        }
        pedalKeycodes = keycodes
    }

    private func isPedalKeystroke(keycode: Int64, down: Bool, repeating: Bool, keyboardType: Int64) -> Bool {
        let now = CFAbsoluteTimeGetCurrent()
        // Once the pedal's keyboard type is known, another device's event for
        // the same keycode is never the pedal's, even if macOS flagged it as a
        // repeat of the key the pedal is holding.
        if let pedalKeyboardType, keyboardType != pedalKeyboardType {
            if verbose && pedalOwned.contains(keycode) {
                log("keyboard typed \(name(for: keycode)) while the pedal holds it — passing it through")
            }
            return false
        }
        if down {
            if repeating { return pedalOwned.contains(keycode) }
            guard let pressedAt = pedalPressedAt[keycode] else { return false }
            pedalPressedAt[keycode] = nil
            guard now - pressedAt <= pressWindow else { return false }
            pedalOwned.insert(keycode)
            if pedalKeyboardType == nil {
                pedalKeyboardType = keyboardType
                if verbose { log("pedal keystrokes carry keyboard type \(keyboardType)") }
            }
            return true
        }
        if pedalOwned.contains(keycode) { return true }
        guard let releasedAt = pedalReleasedAt[keycode] else { return false }
        pedalReleasedAt[keycode] = nil
        return now - releasedAt <= releaseGrace
    }

    private func setTrigger(down: Bool) {
        guard down != triggerDown else { return }
        triggerDown = down
        if down {
            triggerDownAt = CFAbsoluteTimeGetCurrent()
            lastTypedAt = 0
            shiftedKeys = 0
            if verbose { log("pedal down") }
        } else {
            let held = CFAbsoluteTimeGetCurrent() - triggerDownAt
            if verbose {
                log(String(format: "pedal up — held %.2fs, shifted %d key(s)", held, shiftedKeys))
            }
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write("  \(message)\n".data(using: .utf8)!)
    }
}

// MARK: - pick: learn a keycode

/// Wall-clock origin for `pick`, so held keys can be told apart from taps.
let pickStart = CFAbsoluteTimeGetCurrent()
/// Time each keycode went down, to measure how long it stayed down.
var pickDownAt: [Int64: CFAbsoluteTime] = [:]

/// Prints every key event so you can discover what the pedal actually sends.
/// The elapsed/held columns answer the make-or-break question: does the pedal
/// hold its key down while your foot is down, or does it only send a tap?
func pickKeycode() -> Never {
    requireAccessibility()

    let mask =
        (1 << CGEventType.keyDown.rawValue)
        | (1 << CGEventType.keyUp.rawValue)
        | (1 << CGEventType.flagsChanged.rawValue)

    let callback: CGEventTapCallBack = { _, type, event, _ in
        let keycode = event.getIntegerValueField(.keyboardEventKeycode)
        let kind: String
        switch type {
        case .keyDown: kind = "down"
        case .keyUp: kind = "up  "
        case .flagsChanged: kind = "flag"
        default: return Unmanaged.passUnretained(event)
        }
        let now = CFAbsoluteTimeGetCurrent()
        // A held key auto-repeats. Only the first down starts the clock, or the
        // measured hold time collapses to the gap between repeats.
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        var label = kind
        var held = ""
        if type == .keyDown {
            if isRepeat {
                label = "rept"
            } else {
                pickDownAt[keycode] = now
            }
        } else if type == .keyUp, let downAt = pickDownAt.removeValue(forKey: keycode) {
            held = String(format: "  held %.2fs", now - downAt)
        }
        let at = String(format: "%7.2fs", now - pickStart)
        print("\(at)  \(label)  keycode \(keycode)\t\(name(for: keycode))\(held)")
        return Unmanaged.passUnretained(event)
    }

    guard
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: callback,
            userInfo: nil)
    else {
        fail("Could not create the event tap. Grant Accessibility to your terminal app.")
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    print("Press the key (or the pedal) you want to use as the trigger.")
    print("Hold it down for a few seconds: 'held' should match how long you held it.")
    print("Ctrl+C to quit.\n")
    CFRunLoopRun()
    exit(0)
}

// MARK: - list: HID devices

/// Lists keyboard-like HID devices. The pedal will show up here once plugged in,
/// which is how the shipping app will tell it apart from the real keyboard.
func listDevices() -> Never {
    let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    let matches =
        [
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
            ],
            [
                kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
                kIOHIDDeviceUsageKey: kHIDUsage_GD_Keypad,
            ],
        ] as CFArray
    IOHIDManagerSetDeviceMatchingMultiple(manager, matches)
    IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))

    guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, !devices.isEmpty
    else {
        print("No keyboard-like HID devices found.")
        print("(Input Monitoring permission may be required.)")
        exit(0)
    }

    func string(_ device: IOHIDDevice, _ key: String) -> String {
        (IOHIDDeviceGetProperty(device, key as CFString) as? String) ?? "-"
    }
    func number(_ device: IOHIDDevice, _ key: String) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }

    print("Keyboard-like HID devices:\n")
    for device in devices {
        let vendor = number(device, kIOHIDVendorIDKey).map { String(format: "0x%04x", $0) } ?? "-"
        let product = number(device, kIOHIDProductIDKey).map { String(format: "0x%04x", $0) } ?? "-"
        print("  \(string(device, kIOHIDProductKey))")
        print("    vendor \(vendor)  product \(product)  by \(string(device, kIOHIDManufacturerKey))")
    }
    exit(0)
}

// MARK: - program: write the pedal's own configuration

/// Talks to the PCsensor pedal's configuration interface (HID usage 1/0, 8-byte
/// reports, no report IDs) with the protocol of the open-source `footswitch`
/// CLI, so the app can set what each pedal sends without ElfKey. This
/// interface opens with plain user permissions. The setting persists in the
/// pedal across unplugging.
final class PedalProgrammer {
    private let device: IOHIDDevice
    private var inputBuffer = [UInt8](repeating: 0, count: 8)
    private var lastReport: [UInt8]?

    /// Finds the configuration interface of the given device, or nil.
    init?(vendor: Int, product: Int) {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: NSDictionary = [
            kIOHIDVendorIDKey: vendor, kIOHIDProductIDKey: product,
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop, kIOHIDPrimaryUsageKey: 0,
        ]
        IOHIDManagerSetDeviceMatching(manager, match)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>, let device = devices.first
        else { return nil }
        self.device = device
    }

    func open() -> IOReturn {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { return result }
        let callback: IOHIDReportCallback = { context, _, _, _, _, report, length in
            guard let context else { return }
            let me = Unmanaged<PedalProgrammer>.fromOpaque(context).takeUnretainedValue()
            me.lastReport = Array(UnsafeBufferPointer(start: report, count: length))
        }
        inputBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer.baseAddress!, buffer.count, callback, Unmanaged.passUnretained(self).toOpaque())
        }
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)
        return kIOReturnSuccess
    }

    private func write(_ bytes: [UInt8]) {
        precondition(bytes.count == 8)
        let result = bytes.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), buffer.baseAddress!, 8)
        }
        if result != kIOReturnSuccess { fail("writing to the pedal failed: \(ioReturnName(result))") }
        usleep(30_000)  // the pedal needs a pause between writes
    }

    private func readReport(timeout: CFTimeInterval) -> [UInt8]? {
        lastReport = nil
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while lastReport == nil && CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.05, true)
        }
        return lastReport
    }

    /// Reads what each of the three pedals is set to.
    func read() -> [String] {
        (1...3).map { pedal in
            write([0x01, 0x82, 0x08, UInt8(pedal), 0, 0, 0, 0])
            guard let r = readReport(timeout: 1) else { return "no answer" }
            switch r[1] {
            case 0: return "unconfigured"
            case 1, 0x81:
                var parts: [String] = []
                let modifiers: [(UInt8, String)] = [
                    (0x01, "ctrl"), (0x02, "shift"), (0x04, "alt"), (0x08, "win"),
                    (0x10, "r_ctrl"), (0x20, "r_shift"), (0x40, "r_alt"), (0x80, "r_win"),
                ]
                for (bit, name) in modifiers where r[2] & bit != 0 { parts.append(name) }
                if r[3] != 0 { parts.append(usageNames[r[3]] ?? String(format: "usage 0x%02x", r[3])) }
                return parts.isEmpty ? "key (none)" : parts.joined(separator: "+")
            case 2: return "mouse"
            case 3: return "key+mouse"
            case 4: return "string"
            default: return "unknown: " + r.map { String(format: "%02x", $0) }.joined(separator: " ")
            }
        }
    }

    /// Sets the three pedals to plain keys (keyboard-page HID usages, e.g.
    /// 0x68 = F13). The protocol always rewrites all three.
    func set(usages: [UInt8]) {
        precondition(usages.count == 3)
        write([0x01, 0x80, 0x08, 0, 0, 0, 0, 0])
        usleep(1_000_000)
        for (i, usage) in usages.enumerated() {
            write([0x01, 0x81, 0x08, UInt8(i + 1), 0, 0, 0, 0])
            write([0x08, 0x01, 0x00, usage, 0, 0, 0, 0])
        }
    }
}

/// Key names accepted by `program`, → HID keyboard-page usage.
let usageForName: [String: UInt8] = {
    var t: [String: UInt8] = ["none": 0, "enter": 0x28, "esc": 0x29, "backspace": 0x2a, "tab": 0x2b, "space": 0x2c]
    for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() { t[String(c)] = UInt8(4 + i) }
    for (i, c) in "1234567890".enumerated() { t[String(c)] = UInt8(30 + i) }
    for n in 1...12 { t["f\(n)"] = UInt8(0x3a + n - 1) }
    for n in 13...24 { t["f\(n)"] = UInt8(0x68 + n - 13) }
    return t
}()
let usageNames: [UInt8: String] = Dictionary(usageForName.map { ($1, $0) }, uniquingKeysWith: { a, _ in a })

func programPedal(args: [String]) -> Never {
    let defaultDevice = (vendor: 0x3553, product: 0xb001)
    guard let programmer = PedalProgrammer(vendor: defaultDevice.vendor, product: defaultDevice.product) else {
        fail("No PCsensor pedal found (looking for its configuration interface).")
    }
    let opened = programmer.open()
    guard opened == kIOReturnSuccess else { fail("Could not open the pedal's configuration interface: \(ioReturnName(opened))") }

    func show(_ label: String) {
        print(label)
        for (i, setting) in programmer.read().enumerated() { print("  pedal \(i + 1): \(setting)") }
    }

    if args.isEmpty {
        show("Current settings:")
        exit(0)
    }
    guard args.count == 1 || args.count == 3 else {
        fail("Give one key for all three pedals, or three keys (one per pedal).")
    }
    let usages: [UInt8] = args.map { keyName in
        if keyName.hasPrefix("0x"), let value = UInt8(keyName.dropFirst(2), radix: 16) { return value }
        if let value = usageForName[keyName.lowercased()] { return value }
        fail("Unknown key '\(keyName)'. Use a letter, digit, f1–f24, enter, esc, space, tab, none, or 0x<usage>.")
    }
    let perPedal = usages.count == 3 ? usages : [usages[0], usages[0], usages[0]]
    show("Before:")
    print("Setting pedals to " + perPedal.map { usageNames[$0] ?? String(format: "0x%02x", $0) }.joined(separator: ", ") + " …")
    programmer.set(usages: perPedal)
    usleep(300_000)
    show("After:")
    exit(0)
}

// MARK: - Helpers

func requireAccessibility() {
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    if !AXIsProcessTrustedWithOptions(options) {
        fail(
            """
            Accessibility permission is required.
            Approve the prompt, or add your terminal app under
            System Settings > Privacy & Security > Accessibility,
            then run this again.
            """)
    }
}

/// Human-readable IOReturn, for the few codes the device open can produce.
func ioReturnName(_ code: IOReturn) -> String {
    let known: [IOReturn: String] = [
        kIOReturnNotPermitted: "not permitted (Input Monitoring)",
        kIOReturnNotPrivileged: "not privileged (seizing a keyboard needs root)",
        kIOReturnExclusiveAccess: "exclusive access (already seized by another process)",
        kIOReturnNotFound: "not found",
        kIOReturnNoDevice: "no device",
        kIOReturnNotOpen: "not open",
        kIOReturnUnsupported: "unsupported",
    ]
    let hex = String(format: "0x%08x", UInt32(bitPattern: code))
    return known[code].map { "\($0), \(hex)" } ?? hex
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("shooft: \(message)\n".data(using: .utf8)!)
    exit(1)
}

func usage() -> Never {
    print(
        """
        shooft — foot-pedal Shift for macOS (prototype)

          shooft pick                    show what each key/pedal sends
          shooft list                    list keyboard-like HID devices
          shooft run [options]           hold the trigger, type, get capitals
          shooft program                 show what each pedal is set to send
          shooft program f13             set all three pedals to F13 (persists
                                        in the pedal; no ElfKey needed)
          shooft program a b c           set each pedal (factory default)

        run options:
          --device <v:p>    watch this HID device as the pedal, whatever key it
                            sends (e.g. 3553:b001, the PCsensor FootSwitch).
                            No remapping tool needed; the pedal's own keystrokes
                            are dropped in the event tap.
          --seize           with --device, take the device over so its
                            keystrokes never reach macOS at all. Needs root
                            (sudo): macOS refuses to seize a keyboard otherwise.
          --keycode <n>     use a keycode as the trigger instead (105 = F13)
          --max-hold <sec>  drop Shift after holding this long without typing
                            (default 0 = never)
          --quiet           no per-keystroke logging

        With neither --device nor --keycode, shooft looks for a PCsensor
        FootSwitch and falls back to F13.
        """)
    exit(0)
}

// MARK: - Entry

setlinebuf(stdout)  // keep logs readable when redirected to a file

var args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { usage() }
args.removeFirst()

switch command {
case "pick": pickKeycode()
case "list": listDevices()
case "program": programPedal(args: args)
case "run":
    /// PCsensor FootSwitch, as reported by `shooft list`.
    let defaultDevice = (vendor: 0x3553, product: 0xb001)

    var keycode: Int64?
    var deviceIDs: (vendor: Int, product: Int)?
    var seize = false
    var maxHold: Double = 0
    var verbose = true

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--device":
            index += 1
            let parts = (index < args.count ? args[index] : "").split(separator: ":")
            guard parts.count == 2,
                let vendor = Int(parts[0], radix: 16),
                let product = Int(parts[1], radix: 16)
            else {
                fail("--device needs vendor:product in hex, e.g. 3553:b001")
            }
            deviceIDs = (vendor, product)
        case "--seize":
            seize = true
        case "--keycode":
            index += 1
            guard index < args.count, let value = Int64(args[index]) else {
                fail("--keycode needs a number")
            }
            keycode = value
        case "--max-hold":
            index += 1
            guard index < args.count, let value = Double(args[index]) else {
                fail("--max-hold needs a number of seconds")
            }
            maxHold = value
        case "--quiet":
            verbose = false
        default:
            fail("unknown option \(args[index])")
        }
        index += 1
    }
    if keycode == nil && deviceIDs == nil {
        deviceIDs = defaultDevice  // try the pedal; fall back to F13 below
    }

    let shift = PedalShift(triggerKeycode: keycode, maxHold: maxHold, verbose: verbose)

    if let deviceIDs {
        let ids = String(format: "%04x:%04x", deviceIDs.vendor, deviceIDs.product)
        let result = shift.watch(vendor: deviceIDs.vendor, product: deviceIDs.product, seize: seize)
        if result == kIOReturnSuccess {
            print("Watching device \(ids)\(seize ? " (seized)" : "")")
        } else if keycode == nil && args.isEmpty {
            print("No pedal found (\(ioReturnName(result))) — falling back to F13.")
            PedalShift(triggerKeycode: 105, maxHold: maxHold, verbose: verbose).run()
        } else {
            var hint = """
                Grant Input Monitoring to your terminal app under
                System Settings > Privacy & Security > Input Monitoring,
                then run this again.
                """
            if seize && result == kIOReturnNotPrivileged {
                hint = "Seizing a keyboard needs root. Run with sudo, or drop --seize."
            }
            fail("Could not open device \(ids): \(ioReturnName(result)).\n\(hint)")
        }
    }

    shift.run()
default:
    usage()
}
