import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem!
    private var window: NSWindow?
    private var model: AppModel!
    private var stateObserver: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        model = AppModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "shoeprints.fill", accessibilityDescription: "shooft")
            ?? NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "shooft")
        statusItem.button?.image?.isTemplate = true
        statusItem.menu = buildMenu()

        // Refresh the menu's status line whenever the model changes.
        stateObserver = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.statusItem.menu = self?.buildMenu() }
        }

        // Do not call the system permission prompt here: macOS shows it from a
        // separate process that outlives this app, so quitting would leave an
        // orphan "Accessibility Access" dialog behind. The settings window has a
        // button that asks for the permission when the user wants it.
        if !ShiftEngine.accessibilityGranted {
            showSettings()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.engine.stop()
        return .terminateNow
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        let status = NSMenuItem(title: statusLine, action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "설정…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "shooft 종료", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }

    private var statusLine: String {
        if !model.engineRunning { return "손쉬움 권한이 필요합니다" }
        if !model.pedalConnected { return "동작 중 · 페달 없음" }
        if let s = model.deviceSettings { return "동작 중 · " + s.map(\.summary).joined(separator: " / ") }
        return "동작 중"
    }

    @objc func showSettings() {
        if window == nil {
            let view = SettingsView(model: model)
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(contentViewController: hosting)
            window.title = "shooft"
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.isReleasedWhenClosed = false
            window.center()
            window.delegate = self
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.stopRecording()
    }
}
