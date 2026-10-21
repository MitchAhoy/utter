import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private let model = AppModel()
    /// Menu items showing Groq's daily allowance; rebuilt each time the menu opens.
    private var usageItems: [NSMenuItem] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if NSClassFromString("XCTestCase") == nil,
           let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter({ $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated })
            .first {
            if let url = existing.bundleURL { NSWorkspace.shared.open(url) }
            NSApp.terminate(nil)
            return
        }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Utter.MenuBar"
        item.isVisible = true
        item.button?.title = "Utter"
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Utter") {
            image.isTemplate = true
            image.size = NSSize(width: 16, height: 16)
            item.button?.image = image
            item.button?.imagePosition = .imageLeading
        }
        item.button?.toolTip = "Utter"
        item.button?.setAccessibilityLabel("Utter")

        let menu = NSMenu(title: "Utter")
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit Utter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)
        menu.delegate = self
        item.menu = menu
        statusItem = item
        if NSClassFromString("XCTestCase") == nil {
            model.start()
            if !model.accessibilityGranted || !model.microphoneGranted { showSettings() }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        for item in usageItems { menu.removeItem(item) }
        usageItems = Self.usageMenuItems(GroqUsageStore.shared.all(), now: Date())
        for (offset, item) in usageItems.enumerated() { menu.insertItem(item, at: offset) }
    }

    /// "Groq · left today" header, one line per model, and a separator. Empty until the first Groq reply.
    static func usageMenuItems(_ snapshots: [GroqUsageSnapshot], now: Date) -> [NSMenuItem] {
        guard !snapshots.isEmpty else { return [] }
        var items = [NSMenuItem.sectionHeader(title: "Groq · left today")]
        for snapshot in snapshots {
            let left = snapshot.estimatedRemaining(at: now)
            let detail = left < snapshot.limit && snapshot.fullAt > now
                ? "full in \(GroqUsageStore.describe(snapshot.fullAt.timeIntervalSince(now)))" : nil
            // The title stays for VoiceOver and tests; the view shows the coloured bar.
            let title = "\(snapshot.title): \(left.formatted()) of \(snapshot.limit.formatted())" + (detail.map { " · \($0)" } ?? "")
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            let row = NSHostingView(rootView: UsageMenuRow(title: snapshot.title, remaining: left, limit: snapshot.limit, detail: detail))
            row.frame.size = row.fittingSize
            item.view = row
            items.append(item)
        }
        items.append(.separator())
        return items
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.isVisible = true
        showSettings()
        return true
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 840, height: 690),
                                  styleMask: [.titled, .closable, .miniaturizable],
                                  backing: .buffered, defer: false)
            window.title = "Utter Settings"
            window.contentView = NSHostingView(rootView: RecordingSettingsView(model: model))
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
        model.refreshPermissions()
        model.refreshMicrophones()
        model.launchAtLogin.refresh()
        model.cloud.refreshKeys()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }
}
