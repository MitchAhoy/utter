import AppKit
import ApplicationServices
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let pushToTalk = Self("pushToTalk")
}

@MainActor
protocol HotkeyMonitor: AnyObject {
    var choice: HotkeyChoice { get set }
    func start(handler: @escaping @MainActor (HotkeyEvent) -> Void) throws
    func stop()
}

@MainActor
final class EventTapHotkeyMonitor: HotkeyMonitor {
    var choice: HotkeyChoice = .rightOption {
        didSet {
            guard choice != oldValue else { return }
            handler?(.cancel)
            state.reset()
            updateCustomShortcut()
        }
    }
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var handler: (@MainActor (HotkeyEvent) -> Void)?
    private var state = HotkeyState()

    init() {
        KeyboardShortcuts.onKeyDown(for: .pushToTalk) { [weak self] in
            guard let self, self.tap != nil, self.choice == .custom,
                  let event = self.state.transition(pressed: true) else { return }
            self.handler?(event)
        }
        KeyboardShortcuts.onKeyUp(for: .pushToTalk) { [weak self] in
            guard let self, self.choice == .custom,
                  let event = self.state.transition(pressed: false) else { return }
            self.handler?(event)
        }
        KeyboardShortcuts.disable(.pushToTalk)
    }

    private func updateCustomShortcut() {
        if choice == .custom && tap != nil {
            KeyboardShortcuts.enable(.pushToTalk)
        } else {
            KeyboardShortcuts.disable(.pushToTalk)
        }
    }

    func start(handler: @escaping @MainActor (HotkeyEvent) -> Void) throws {
        self.handler = handler
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else {
            throw RecordingError.message("Enable Accessibility for Utter in System Settings, then retry.")
        }
        let mask = CGEventMask(1) << CGEventType.flagsChanged.rawValue
        guard let newTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<EventTapHotkeyMonitor>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { monitor.receive(type: type, event: event) }
                return Unmanaged.passUnretained(event)
            }, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            throw RecordingError.message("Unable to monitor the shortcut. Check Accessibility and retry.")
        }
        guard let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newTap, 0) else {
            CFMachPortInvalidate(newTap)
            throw RecordingError.message("Unable to create the keyboard event source.")
        }
        tap = newTap
        source = newSource
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newTap, enable: true)
        updateCustomShortcut()
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            state.reset()
            handler?(.cancel)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged, choice != .custom else { return }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let pressed = choice == .fn
            ? event.flags.contains(.maskSecondaryFn)
            : CGEventSource.keyState(.combinedSessionState, key: code)
        if let change = state.update(keyCode: code, pressed: pressed, choice: choice) {
            handler?(change)
        }
    }

    func stop() {
        KeyboardShortcuts.disable(.pushToTalk)
        handler?(.cancel)
        state.reset()
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        handler = nil
    }
}
