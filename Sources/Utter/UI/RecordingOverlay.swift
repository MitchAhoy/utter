import AppKit
import SwiftUI

@MainActor
private final class OverlayModel: ObservableObject {
    @Published var state: OverlayState = .processing("")
}

private struct PillView: View {
    @ObservedObject var model: OverlayModel
    var body: some View {
        HStack(spacing: 12) {
            switch model.state {
            case .listening(let level, let seconds):
                Image(systemName: "mic.fill").foregroundStyle(.red)
                Text("Listening").fontWeight(.medium)
                HStack(spacing: 3) {
                    ForEach(0..<12) { index in
                        Capsule().fill(Float(index) / 12 < level ? Color.green : Color.white.opacity(0.18))
                            .frame(width: 4, height: CGFloat(8 + (index % 4) * 4))
                    }
                }
                .accessibilityLabel("Microphone level \(Int(level * 100)) percent")
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60)).monospacedDigit()
            case .processing(let path):
                ProgressView().controlSize(.small)
                Text(path.isEmpty ? "Processing…" : "Processing · \(path)…")
            case .complete(let message):
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text(message)
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
    private let model = OverlayModel()
    private let panel: NSPanel
    private var isVisible = false

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
        let host = NSHostingView(rootView: PillView(model: model))
        host.sizingOptions = [.minSize, .intrinsicContentSize]
        panel.contentView = host
        panel.setAccessibilityLabel("Utter recording status")
    }

    func show(_ state: OverlayState) {
        model.state = state
        let screen = isVisible ? panel.screen : focusedScreen()
        let frame = (screen ?? NSScreen.main)?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let ideal = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 70)
        let size = NSSize(width: min(520, max(220, ideal.width)), height: max(64, ideal.height))
        panel.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY + 28,
                              width: size.width, height: size.height), display: true)
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
                        return NSScreen.screens.first { $0.frame.contains(center) }
                    }
                }
            }
        }
        return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    }
}
