import AppKit
import Carbon

@MainActor
final class SystemPasteEnvironment: PasteEnvironment {
    var accessibilityGranted: Bool { AXIsProcessTrusted() }
    var secureInput: Bool { IsSecureEventInputEnabled() }
    var focusedProcessID: Int32? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var ownProcessID: Int32 { ProcessInfo.processInfo.processIdentifier }

    func postPaste() throws {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            throw InsertionError.keyboardUnavailable
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}

@MainActor
final class ClipboardTextInserter: TextInserter {
    private let clipboard: any ClipboardAccess
    private let environment: any PasteEnvironment
    private let waitForPaste: @MainActor () async throws -> Void
    private var busy = false

    init(clipboard: any ClipboardAccess = SystemPasteboard(),
         environment: any PasteEnvironment = SystemPasteEnvironment(),
         waitForPaste: @escaping @MainActor () async throws -> Void = {
             try await Task.sleep(for: .milliseconds(300))
         }) {
        self.clipboard = clipboard
        self.environment = environment
        self.waitForPaste = waitForPaste
    }

    func insert(_ text: String, target: InsertionTarget) async throws {
        guard !busy else { throw InsertionError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw InsertionError.emptyText }
        try Task.checkCancellation()
        try validate(target)
        busy = true
        defer { busy = false }
        let original = try clipboard.snapshot()
        let ownedCount = try clipboard.writeText(text, transient: true, rollback: original)
        defer { clipboard.restore(original, ifUnchanged: ownedCount) }
        try Task.checkCancellation()
        try validate(target)
        try environment.postPaste()
        // Restoration also runs on cancellation or errors, and only while we own the clipboard.
        try await waitForPaste()
    }

    private func validate(_ target: InsertionTarget) throws {
        guard environment.accessibilityGranted else { throw InsertionError.accessibilityRequired }
        guard !environment.secureInput else { throw InsertionError.secureInput }
        guard target.processID != environment.ownProcessID,
              environment.focusedProcessID == target.processID else { throw InsertionError.focusChanged }
    }

    func copyForRecovery(_ text: String) throws {
        guard !text.isEmpty else { return }
        _ = try clipboard.writeText(text, transient: false, rollback: nil)
    }
}
