import Foundation

enum HotkeyChoice: String, CaseIterable, Identifiable {
    case rightOption, fn, rightCommand, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .rightOption: "Right Option"
        case .fn: "Fn / Globe"
        case .rightCommand: "Right Command"
        case .custom: "Custom shortcut"
        }
    }
    var keyCode: UInt16? {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .fn: 63
        case .custom: nil
        }
    }
}

enum HotkeyEvent: Equatable { case down, up, cancel }

/// Deduplicates repeated presses and filters the left/right modifier key codes.
struct HotkeyState {
    private(set) var isDown = false
    mutating func update(keyCode: UInt16, pressed: Bool, choice: HotkeyChoice) -> HotkeyEvent? {
        guard keyCode == choice.keyCode else { return nil }
        return transition(pressed: pressed)
    }
    mutating func transition(pressed: Bool) -> HotkeyEvent? {
        guard pressed != isDown else { return nil }
        isDown = pressed
        return pressed ? .down : .up
    }
    mutating func reset() { isDown = false }
}

/// Tap once to start recording, tap again to stop. Used for buttons that only send
/// a quick press, such as a DJI mic button remapped to F18 with Karabiner.
struct ToggleState {
    private(set) var active = false
    mutating func tap(isRecording: Bool) -> HotkeyEvent? {
        if isRecording {
            // A hold-to-talk recording in progress is left alone.
            guard active else { return nil }
            active = false
            return .up
        }
        active = true
        return .down
    }
    /// Call whenever recording stops for any reason (deadline, cancel, failure).
    mutating func recordingEnded() { active = false }
}
