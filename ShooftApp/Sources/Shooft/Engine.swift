import ApplicationServices
import CoreGraphics
import Foundation
import os

private let logger = Logger(subsystem: "com.jinsukim.shooft", category: "engine")
/// Visible with: log show --last 5m --predicate 'subsystem == "com.jinsukim.shooft"'
/// Also appended to ~/Library/Logs/shooft.log (inside the container for a sandboxed build).
func shooftLog(_ message: String) {
    logger.notice("\(message, privacy: .public)")
    let line = "\(Date()) \(message)\n"
    let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/shooft.log")
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile(); handle.write(line.data(using: .utf8)!); try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// The active event tap. While a foot modifier's key (F13–F16) is held, every
/// keystroke passing through gets that modifier's flag added in place. Nothing
/// is delayed, buffered or re-posted, so typing feels exactly like a keyboard
/// modifier. Needs the Accessibility permission.
final class ShiftEngine {
    private(set) var isRunning = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var held = Set<Int64>()
    private var activeFlags: CGEventFlags = []

    /// Called on the main thread when a foot modifier goes down or up.
    var onHeldChange: ((Set<FootModifier>) -> Void)?

    static var accessibilityGranted: Bool {
        AXIsProcessTrusted()
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }
        let mask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let engine = Unmanaged<ShiftEngine>.fromOpaque(refcon).takeUnretainedValue()
            return engine.handle(type: type, event: event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: CGEventMask(mask),
                callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            shooftLog("CGEvent.tapCreate failed")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        isRunning = true
        return true
    }

    func stop() {
        guard isRunning, let tap, let source else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        self.tap = nil
        self.source = nil
        held.removeAll()
        activeFlags = []
        isRunning = false
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return nil
        }

        let keycode = event.getIntegerValueField(.keyboardEventKeycode)

        if let modifier = FootModifier.from(keycode: keycode) {
            if type == .keyDown {
                if held.insert(keycode).inserted { heldChanged() }
            } else if type == .keyUp {
                if held.remove(keycode) != nil { heldChanged() }
            }
            _ = modifier
            return nil  // the pedal's key never reaches any app
        }

        guard !activeFlags.isEmpty, type == .keyDown || type == .keyUp else {
            return Unmanaged.passUnretained(event)
        }
        event.flags.insert(activeFlags)
        return Unmanaged.passUnretained(event)
    }

    private func heldChanged() {
        var flags: CGEventFlags = []
        var modifiers = Set<FootModifier>()
        for keycode in held {
            if let m = FootModifier.from(keycode: keycode) {
                flags.insert(m.flags)
                modifiers.insert(m)
            }
        }
        activeFlags = flags
        if let onHeldChange {
            DispatchQueue.main.async { onHeldChange(modifiers) }
        }
    }
}
