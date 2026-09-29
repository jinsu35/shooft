import AppKit
import Foundation
import ServiceManagement
import SwiftUI

/// Editable state for one pedal row in the settings window. One choice list:
/// the foot modifiers (held while pressed, need the app) come first, then the
/// plain keys the pedal types by itself.
struct PedalRow: Equatable {
    /// "foot:shift" … or a PlainKey id, or "custom".
    var choice: String = "foot:shift"
    var customUsage: UInt8? = nil  // a key this app has no name for
    var control = false
    var option = false
    var shift = false
    var command = false
    var other: String? = nil  // mouse/string setting we cannot edit

    init() {}

    init(_ setting: PedalSetting) {
        switch setting {
        case .foot(let m):
            choice = "foot:" + m.rawValue
        case .key(let usage, let mods):
            if let key = PlainKey.from(usage: usage) {
                choice = key.id
            } else {
                choice = "custom"
                customUsage = usage
            }
            control = mods.contains(.control)
            option = mods.contains(.option)
            shift = mods.contains(.shift)
            command = mods.contains(.command)
        case .other(let text):
            choice = "none"
            other = text
        }
    }

    var footModifier: FootModifier? {
        guard choice.hasPrefix("foot:") else { return nil }
        return FootModifier(rawValue: String(choice.dropFirst(5)))
    }

    var setting: PedalSetting {
        if let foot = footModifier { return .foot(foot) }
        var mods: PedalModifiers = []
        if control { mods.insert(.control) }
        if option { mods.insert(.option) }
        if shift { mods.insert(.shift) }
        if command { mods.insert(.command) }
        let usage = choice == "custom" ? (customUsage ?? 0) : (PlainKey.all.first { $0.id == choice }?.usage ?? 0)
        return .key(usage: usage, modifiers: mods)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var accessibilityGranted = ShiftEngine.accessibilityGranted
    @Published var engineRunning = false
    @Published var pedalConnected = false
    @Published var rows: [PedalRow] = [PedalRow(), PedalRow(), PedalRow()]
    @Published var deviceSettings: [PedalSetting]? = nil
    @Published var busy = false
    @Published var status = ""
    @Published var heldModifiers = Set<FootModifier>()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    let engine = ShiftEngine()
    let pedal = PedalController()
    private var permissionTimer: Timer?

    init() {
        engine.onHeldChange = { [weak self] held in self?.heldModifiers = held }
        pedal.onConnectionChange = { [weak self] connected in
            guard let self else { return }
            self.pedalConnected = connected
            if connected {
                self.status = "페달을 찾았습니다. 설정을 읽는 중…"
                self.refreshFromPedal(autoSetup: true)
            } else {
                self.status = "페달이 연결되어 있지 않습니다."
                self.deviceSettings = nil
            }
        }
        startEngineIfPermitted()
    }

    var hasUnsavedChanges: Bool {
        guard let deviceSettings else { return false }
        return rows.map(\.setting) != deviceSettings
    }

    // MARK: Permission and engine

    func startEngineIfPermitted() {
        accessibilityGranted = ShiftEngine.accessibilityGranted
        engineRunning = accessibilityGranted && engine.start()
        if accessibilityGranted != lastLoggedGranted || engineRunning != lastLoggedRunning {
            shooftLog("accessibility trusted=\(accessibilityGranted) engine running=\(engineRunning)")
            lastLoggedGranted = accessibilityGranted
            lastLoggedRunning = engineRunning
        }
        if engineRunning {
            permissionTimer?.invalidate()
            permissionTimer = nil
        } else if permissionTimer == nil {
            // Keep checking: the user may grant the permission any time, and a tap
            // that failed to start (e.g. right as the permission was toggled) is retried.
            let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.startEngineIfPermitted() }
            }
            RunLoop.main.add(timer, forMode: .common)
            permissionTimer = timer
        }
    }
    private var lastLoggedGranted: Bool? = nil
    private var lastLoggedRunning: Bool? = nil

    func requestAccessibility() {
        ShiftEngine.requestAccessibility()
        startEngineIfPermitted()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Pedal settings

    /// Reads the pedal. With `autoSetup`, a pedal still at its factory a/b/c is
    /// switched to Shift on all three, so the first plug-in needs no setup.
    func refreshFromPedal(autoSetup: Bool = false) {
        guard pedalConnected, !busy else { return }
        busy = true
        pedal.readSettings { [weak self] settings in
            guard let self else { return }
            self.busy = false
            guard let settings else {
                self.status = "페달 설정을 읽지 못했습니다."
                return
            }
            if autoSetup && settings == PedalSetting.factoryDefault {
                self.status = "새 페달입니다. 세 페달을 모두 Shift로 설정하는 중…"
                self.apply(PedalSetting.allShift)
                return
            }
            self.deviceSettings = settings
            self.rows = settings.map(PedalRow.init)
            self.status = "페달 설정을 읽었습니다."
        }
    }

    func applyRows() {
        apply(rows.map(\.setting))
    }

    private func apply(_ settings: [PedalSetting]) {
        guard pedalConnected, !busy else { return }
        busy = true
        pedal.writeSettings(settings) { [weak self] result in
            guard let self else { return }
            self.busy = false
            guard let result else {
                self.status = "페달에 쓰지 못했습니다. 다시 꽂고 시도해 보세요."
                return
            }
            self.deviceSettings = result
            self.rows = result.map(PedalRow.init)
            self.status = result == settings ? "페달에 저장했습니다." : "저장했지만 페달이 다른 값을 돌려줬습니다."
        }
    }

    /// Puts the rows back to what the pedal currently holds.
    func discardChanges() {
        stopRecording()
        if let deviceSettings { rows = deviceSettings.map(PedalRow.init) }
    }

    // MARK: Key recording ("press the key you want")

    @Published var recordingRow: Int? = nil
    private var keyMonitor: Any?
    private var pendingFootModifier: FootModifier?

    /// Captures the next key pressed in this app's window and puts it into
    /// `rows[index]`. A modifier key pressed and released by itself becomes a
    /// "held while pressed" foot modifier; any other key (with whatever
    /// modifiers were down) becomes a plain key. Escape cancels.
    func startRecording(row index: Int) {
        stopRecording()
        recordingRow = index
        pendingFootModifier = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self, let index = self.recordingRow else { return event }
            if event.type == .flagsChanged {
                let down = event.modifierFlags.intersection([.shift, .control, .option, .command])
                if down.isEmpty {
                    if let foot = self.pendingFootModifier {
                        self.rows[index] = PedalRow(.foot(foot))
                        self.stopRecording()
                    }
                } else if let foot = FootModifier.from(modifierKeycode: Int(event.keyCode)), self.pendingFootModifier == nil {
                    self.pendingFootModifier = foot
                }
                return nil
            }
            // keyDown
            self.pendingFootModifier = nil
            if event.keyCode == 0x35 && event.modifierFlags.intersection([.shift, .control, .option, .command]).isEmpty {
                self.stopRecording()  // Escape: cancel
                return nil
            }
            guard let key = PlainKey.from(keycode: Int(event.keyCode)) else {
                self.status = "이 키는 페달에 넣을 수 없습니다."
                return nil
            }
            var row = PedalRow(.key(usage: key.usage, modifiers: []))
            row.control = event.modifierFlags.contains(.control)
            row.option = event.modifierFlags.contains(.option)
            row.shift = event.modifierFlags.contains(.shift)
            row.command = event.modifierFlags.contains(.command)
            self.rows[index] = row
            self.stopRecording()
            return nil
        }
    }

    func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingRow = nil
        pendingFootModifier = nil
    }

    // MARK: Launch at login

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            status = "로그인 시 실행 설정 실패: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
