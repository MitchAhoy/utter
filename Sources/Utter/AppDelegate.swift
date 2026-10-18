import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Utter") {
            image.isTemplate = true
            item.button?.image = image
        } else {
            item.button?.title = "U"
        }
        item.button?.toolTip = "Utter"
        item.button?.setAccessibilityLabel("Utter")

        let menu = NSMenu(title: "Utter")
        let quitItem = NSMenuItem(
            title: "Quit Utter",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = NSApp
        menu.addItem(quitItem)
        item.menu = menu
        statusItem = item
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        statusItem = nil
    }
}
