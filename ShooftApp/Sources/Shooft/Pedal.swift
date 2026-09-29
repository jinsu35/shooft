import Foundation
import IOKit.hid

/// Finds the PCsensor pedal, follows it being plugged in and out, and reads or
/// writes what its three pedals send. All I/O happens on a private thread so
/// the UI never waits on the device; results come back on the main thread.
///
/// The pedal's configuration interface (HID usage page 1, usage 0) takes
/// 8-byte output reports with no report IDs. The protocol is the one used by
/// the open-source `footswitch` CLI, which is what ElfKey also speaks.
final class PedalController {
    static let vendorID = 0x3553
    static let productID = 0xB001

    /// Main-thread callbacks.
    var onConnectionChange: ((Bool) -> Void)?

    private(set) var isConnected = false

    private let thread: Thread
    private var runLoop: CFRunLoop!
    private let ready = DispatchSemaphore(value: 0)

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var inputBuffer = [UInt8](repeating: 0, count: 8)
    private var lastReport: [UInt8]?

    init() {
        var loop: CFRunLoop?
        let ready = self.ready
        thread = Thread {
            loop = CFRunLoopGetCurrent()
            // Keep the loop alive even with no sources yet.
            var context = CFRunLoopSourceContext()
            let keepAlive = CFRunLoopSourceCreate(kCFAllocatorDefault, 0, &context)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), keepAlive, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "shooft.pedal"
        thread.start()
        ready.wait()
        runLoop = loop
        perform { self.startWatching() }
    }

    // MARK: Threading

    private func perform(_ block: @escaping () -> Void) {
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Hot-plug

    private func startWatching() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let match: NSDictionary = [
            kIOHIDVendorIDKey: Self.vendorID, kIOHIDProductIDKey: Self.productID,
            kIOHIDPrimaryUsagePageKey: kHIDPage_GenericDesktop, kIOHIDPrimaryUsageKey: 0,
        ]
        IOHIDManagerSetDeviceMatching(manager, match)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                Unmanaged<PedalController>.fromOpaque(context).takeUnretainedValue().attach(device)
            }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(
            manager,
            { context, _, _, device in
                guard let context else { return }
                Unmanaged<PedalController>.fromOpaque(context).takeUnretainedValue().detach(device)
            }, context)
        IOHIDManagerScheduleWithRunLoop(manager, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = manager
    }

    private func attach(_ device: IOHIDDevice) {
        guard self.device == nil else { return }
        guard IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return }
        let callback: IOHIDReportCallback = { context, _, _, _, _, report, length in
            guard let context else { return }
            let me = Unmanaged<PedalController>.fromOpaque(context).takeUnretainedValue()
            me.lastReport = Array(UnsafeBufferPointer(start: report, count: length))
        }
        inputBuffer.withUnsafeMutableBufferPointer { buffer in
            IOHIDDeviceRegisterInputReportCallback(
                device, buffer.baseAddress!, buffer.count, callback, Unmanaged.passUnretained(self).toOpaque())
        }
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        self.device = device
        isConnected = true
        DispatchQueue.main.async { self.onConnectionChange?(true) }
    }

    private func detach(_ device: IOHIDDevice) {
        guard self.device == device else { return }
        self.device = nil
        isConnected = false
        DispatchQueue.main.async { self.onConnectionChange?(false) }
    }

    // MARK: Protocol

    private func write(_ bytes: [UInt8]) -> Bool {
        guard let device else { return false }
        let result = bytes.withUnsafeBufferPointer { buffer in
            IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, CFIndex(bytes[0]), buffer.baseAddress!, bytes.count)
        }
        usleep(30_000)  // the pedal needs a pause between writes
        return result == kIOReturnSuccess
    }

    private func readReport(timeout: CFTimeInterval) -> [UInt8]? {
        lastReport = nil
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while lastReport == nil && CFAbsoluteTimeGetCurrent() < deadline {
            CFRunLoopRunInMode(.defaultMode, 0.02, true)
        }
        return lastReport
    }

    private func readSettingsNow() -> [PedalSetting]? {
        var settings: [PedalSetting] = []
        for pedal in 1...3 {
            guard write([0x01, 0x82, 0x08, UInt8(pedal), 0, 0, 0, 0]), let r = readReport(timeout: 1) else { return nil }
            switch r[1] {
            case 0:
                settings.append(.key(usage: 0, modifiers: []))
            case 1, 0x81:
                let mods = PedalModifiers(rawValue: r[2] & 0x0F)
                if mods.isEmpty, let foot = FootModifier.from(usage: r[3]) {
                    settings.append(.foot(foot))
                } else {
                    settings.append(.key(usage: r[3], modifiers: mods))
                }
            case 2: settings.append(.other("마우스 동작"))
            case 3: settings.append(.other("키+마우스"))
            case 4: settings.append(.other("문자열"))
            default: settings.append(.other("알 수 없음"))
            }
        }
        return settings
    }

    private func writeSettingsNow(_ settings: [PedalSetting]) -> Bool {
        precondition(settings.count == 3)
        guard write([0x01, 0x80, 0x08, 0, 0, 0, 0, 0]) else { return false }
        usleep(1_000_000)
        for (i, setting) in settings.enumerated() {
            guard write([0x01, 0x81, 0x08, UInt8(i + 1), 0, 0, 0, 0]),
                write([0x08, 0x01, setting.modifiers.rawValue, setting.usage, 0, 0, 0, 0])
            else { return false }
        }
        usleep(300_000)
        return true
    }

    // MARK: Public, asynchronous

    func readSettings(_ completion: @escaping ([PedalSetting]?) -> Void) {
        perform {
            let result = self.readSettingsNow()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Writes, then reads back what the pedal now reports.
    func writeSettings(_ settings: [PedalSetting], _ completion: @escaping ([PedalSetting]?) -> Void) {
        perform {
            let ok = self.writeSettingsNow(settings)
            let result = ok ? self.readSettingsNow() : nil
            DispatchQueue.main.async { completion(result) }
        }
    }
}
