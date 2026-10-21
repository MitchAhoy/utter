import AppKit
import SwiftUI

private struct PillView: View {
    let state: OverlayState
    var body: some View {
        HStack(spacing: 12) {
            switch state {
            case .listening(let level, let seconds):
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text("Listening").fontWeight(.medium)
                VoiceWaveView(level: level)
                    .frame(width: 132, height: 30)
                    .accessibilityElement()
                    .accessibilityLabel("Microphone level \(Int(level * 100)) percent")
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
            case .processing(let path):
                ProgressView().controlSize(.small)
                Text(path.isEmpty ? "Processing…" : "Processing · \(path)…")
            case .complete(let message):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message).lineLimit(3)
            case .error(let message):
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                Text(message).lineLimit(3)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 20).padding(.vertical, 14)
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .padding(8)
        .preferredColorScheme(.dark)
    }
}

private final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class RecordingOverlay: OverlayController {
    private let panel: NSPanel
    private let host: NSHostingController<PillView>
    private var isVisible = false
    /// Gap kept between the pill's window and every edge of the usable screen area.
    private let margin: CGFloat = 16

    init() {
        panel = NonActivatingPanel(contentRect: .zero,
                                   styleMask: [.borderless, .nonactivatingPanel],
                                   backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        host = NSHostingController(rootView: PillView(state: .processing("")))
        // The window size is set only in show(); content must never resize it,
        // because AppKit grows windows downward from the top edge and off the screen.
        host.sizingOptions = []
        panel.contentViewController = host
        panel.setAccessibilityLabel("Utter recording status")
    }

    func show(_ state: OverlayState) {
        host.rootView = PillView(state: state)
        let screen = (isVisible ? panel.screen : nil) ?? focusedScreen() ?? NSScreen.main
        // visibleFrame excludes the menu bar and Dock, on any display size or arrangement.
        let area = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let maxWidth = max(160, min(520, area.width - margin * 2))
        let maxHeight = max(64, area.height - margin * 2)
        // Measure the new content at the width it will be shown, so wrapped text is counted.
        let ideal = host.sizeThatFits(in: NSSize(width: maxWidth, height: maxHeight))
        let size = NSSize(width: min(maxWidth, max(220, ideal.width)), height: min(maxHeight, max(64, ideal.height)))
        var origin = NSPoint(x: area.midX - size.width / 2, y: area.minY + 28)
        origin.x = min(max(origin.x, area.minX + margin), area.maxX - margin - size.width)
        origin.y = min(max(origin.y, area.minY + margin), area.maxY - margin - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    func hide() { panel.orderOut(nil); isVisible = false }

    private func focusedScreen() -> NSScreen? {
        let app = NSWorkspace.shared.frontmostApplication
        if let pid = app?.processIdentifier {
            let element = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(element, 0.15)
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
               let value, CFGetTypeID(value) == AXUIElementGetTypeID() {
                let window = unsafeDowncast(value, to: AXUIElement.self)
                var positionValue: CFTypeRef?
                var sizeValue: CFTypeRef?
                AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue)
                AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue)
                if let positionValue, let sizeValue,
                   CFGetTypeID(positionValue) == AXValueGetTypeID(), CFGetTypeID(sizeValue) == AXValueGetTypeID() {
                    var point = CGPoint.zero
                    var size = CGSize.zero
                    let position = unsafeDowncast(positionValue, to: AXValue.self)
                    let dimensions = unsafeDowncast(sizeValue, to: AXValue.self)
                    if AXValueGetValue(position, .cgPoint, &point), AXValueGetValue(dimensions, .cgSize, &size) {
                        let top = NSScreen.screens.first?.frame.maxY ?? 0
                        let center = NSPoint(x: point.x + size.width / 2, y: top - point.y - size.height / 2)
                        if let match = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return match }
                    }
                }
            }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
}
