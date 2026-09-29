// Checks whether a running shooft engine turns a held F13 into Shift.
// Build: swiftc -O scripts/taptest.swift -o /tmp/taptest && /tmp/taptest
// Posts F13 down, F19 down/up, F13 up at the HID level and watches, with a
// listen-only tap at the end of the session chain, what comes out.
import CoreGraphics
import Foundation

var seen: [(String, Int64, Bool)] = []
let cb: CGEventTapCallBack = { _, type, event, _ in
    let k = event.getIntegerValueField(.keyboardEventKeycode)
    let shift = event.flags.contains(.maskShift)
    seen.append((type == .keyDown ? "down" : "up", k, shift))
    return Unmanaged.passUnretained(event)
}
let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
guard let tap = CGEvent.tapCreate(tap: .cgAnnotatedSessionEventTap, place: .tailAppendEventTap,
                                  options: .listenOnly, eventsOfInterest: CGEventMask(mask),
                                  callback: cb, userInfo: nil) else {
    print("no listen tap: this terminal needs Accessibility / Input Monitoring"); exit(2)
}
CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)

func post(_ key: CGKeyCode, down: Bool) {
    let e = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: down)!
    e.flags = []
    e.post(tap: .cghidEventTap)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
    post(105, down: true); usleep(60_000)
    post(80, down: true); usleep(30_000); post(80, down: false); usleep(60_000)
    post(105, down: false)
}
DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
    for (t, k, s) in seen { print("  \(t) keycode=\(k) shift=\(s)") }
    let f13Leaked = seen.contains { $0.1 == 105 }
    let f19 = seen.filter { $0.1 == 80 }
    let shifted = !f19.isEmpty && f19.allSatisfy { $0.2 }
    if shifted && !f13Leaked { print("PASS: F19 arrived with Shift, F13 swallowed") }
    else if f19.isEmpty { print("FAIL: F19 never arrived") }
    else { print("FAIL: shift=\(shifted) f13Leaked=\(f13Leaked) (no engine running?)") }
    exit(shifted && !f13Leaked ? 0 : 1)
}
CFRunLoopRun()
