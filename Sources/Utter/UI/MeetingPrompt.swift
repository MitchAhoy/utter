import AppKit
import SwiftUI

/// A small "Meeting detected" popup in the corner of the screen. It never takes keyboard focus,
/// and nothing is recorded unless Take Notes is clicked.
@MainActor
final class MeetingPrompt {
    private var panel: NSPanel?
    private var dismissal: Task<Void, Never>?

    func show(app: String, takeNotes: @escaping @MainActor () -> Void) {
        close()
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 76),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = NSHostingView(rootView: MeetingPromptView(app: app, takeNotes: { [weak self] in
            self?.close()
            takeNotes()
        }, dismiss: { [weak self] in self?.close() }))
        if let screen = NSScreen.main {
            let area = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: area.maxX - 346, y: area.maxY - 92))
        }
        panel.orderFrontRegardless()
        self.panel = panel
        dismissal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.close()
        }
    }

    func close() {
        dismissal?.cancel(); dismissal = nil
        panel?.orderOut(nil)
        panel = nil
    }
}

private struct MeetingPromptView: View {
    let app: String
    let takeNotes: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Meeting detected").font(.headline)
                Text("\(app) is using the microphone").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Button("Take Notes", action: takeNotes).buttonStyle(.borderedProminent)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Dismiss")
        }
        .padding(12)
        .frame(width: 330, height: 76)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
