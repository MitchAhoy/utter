import AppKit

@MainActor
protocol SelectionReader { func read(target: InsertionTarget) async throws -> String }
@MainActor
struct ClipboardSelectionReader: SelectionReader {
    func read(target: InsertionTarget) async throws -> String {
        let environment = SystemPasteEnvironment()
        guard environment.accessibilityGranted else { throw InsertionError.accessibilityRequired }
        guard !environment.secureInput else { throw InsertionError.secureInput }
        guard environment.focusedProcessID == target.processID else { throw InsertionError.focusChanged }
        let clipboard = SystemPasteboard()
        let original = try clipboard.snapshot()
        let board = NSPasteboard.general
        let before = board.changeCount
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false) else { throw InsertionError.keyboardUnavailable }
        down.flags = .maskCommand; up.flags = .maskCommand
        down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        // Once the copy completes, snapshot its ownership before restoring the original.
        // Restore also on cancellation, while respecting any later clipboard change.
        do { try await Task.sleep(for: .milliseconds(180)) }
        catch {
            if board.changeCount != before { clipboard.restore(original, ifUnchanged: board.changeCount) }
            throw error
        }
        let copied = board.changeCount
        guard copied != before else { throw RecordingError.message("Select some text before using command mode.") }
        defer { clipboard.restore(original, ifUnchanged: copied) }
        guard environment.focusedProcessID == target.processID, !environment.secureInput else { throw InsertionError.focusChanged }
        guard let text = board.string(forType: .string), !text.isEmpty else {
            throw RecordingError.message("The selection does not contain editable text.")
        }
        guard text.count <= 30_000 else {
            throw RecordingError.message("The selection is too long. Select fewer than 30,000 characters and try again.")
        }
        return text
    }
}
