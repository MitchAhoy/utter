import AppKit
import AVFoundation
import KeyboardShortcuts

@MainActor
final class AppModel: ObservableObject {
    @Published var hotkey: HotkeyChoice {
        didSet {
            UserDefaults.standard.set(hotkey.rawValue, forKey: "hotkey")
            monitor.choice = hotkey
        }
    }
    @Published var sounds: Bool {
        didSet { UserDefaults.standard.set(sounds, forKey: "sounds") }
    }
    @Published var debugRecording: Bool {
        didSet { UserDefaults.standard.set(debugRecording, forKey: "debugRecording") }
    }
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var shortcutReady = false
    @Published private(set) var status = "Allow microphone access and enable Accessibility to begin."
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var isRecording = false
    @Published var sampleText = "This is a paste test from Utter."
    @Published private(set) var pasteTestArmed = false
    @Published private(set) var isProcessing = false
    private struct PasteTestRequest {
        let text: String
        let context: DictationContext
    }
    private var pasteTestRequest: PasteTestRequest?
    private let pipeline = DictationPipeline(inserter: ClipboardTextInserter())
    private let monitor = EventTapHotkeyMonitor()
    private let debugStore = DebugRecordingStore()
    private let session = RecordingSession(recorder: EngineAudioRecorder(), overlay: RecordingOverlay())
    private var permissionTask: Task<Void, Never>?
    private var generation = 0

    init() {
        let defaults = UserDefaults.standard
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        sounds = defaults.bool(forKey: "sounds")
        debugRecording = defaults.bool(forKey: "debugRecording")
        monitor.choice = hotkey
        session.onSound = { [weak self] starting in
            guard self?.sounds == true else { return }
            NSSound(named: starting ? "Tink" : "Pop")?.play()
        }
        session.onStateChange = { [weak self] in
            guard let self else { return }
            self.isRecording = self.session.isRecording
            if self.isRecording { self.generation += 1 }
        }
        session.onClip = { [weak self] audio in self?.received(audio) }
        pipeline.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .processing:
                self.isProcessing = true
                self.session.showProcessing()
            case .inserted:
                self.status = "Inserted sample text. Your original clipboard was restored unless it changed during the paste."
                self.session.completed("Sample text inserted")
            case .failed(let message):
                self.status = message
                self.session.showError(message)
            case .idle:
                self.isProcessing = false
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
                                                          name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep),
                                                          name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
    }

    func start() {
        refreshPermissions()
        permissionTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.refreshPermissions()
            }
        }
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        microphoneGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        if !microphoneGranted && session.isRecording {
            session.cancel()
            session.showError("Microphone access was revoked. Allow access in System Settings.")
        }
        if !accessibilityGranted {
            if shortcutReady { monitor.stop() }
            pipeline.cancel()
            shortcutReady = false
            return
        }
        guard !shortcutReady else { return }
        do {
            try monitor.start { [weak self] event in self?.handleHotkey(event) }
            shortcutReady = true
            status = microphoneGranted ? "Ready — hold your shortcut to record." : "Allow microphone access to record."
        } catch {
            status = error.localizedDescription
        }
    }

    func requestMicrophone() async {
        _ = await AVCaptureDevice.requestAccess(for: .audio)
        refreshPermissions()
        if microphoneGranted { status = "Ready — hold your shortcut to record." }
    }

    func openAccessibility() {
        openPane("Privacy_Accessibility")
    }
    func openMicrophone() { openPane("Privacy_Microphone") }
    private func openPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func togglePasteTest() {
        guard !isRecording else { return }
        if pasteTestArmed {
            pasteTestArmed = false
            pasteTestRequest = nil
            status = "Paste test cancelled."
            return
        }
        guard accessibilityGranted, !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Allow Accessibility and enter sample text before arming the paste test."
            return
        }
        pasteTestArmed = true
        status = "Paste test armed. Focus a text field in another app, then hold and release your shortcut."
    }

    private func handleHotkey(_ event: HotkeyEvent) {
        if event == .down, !session.isRecording, pasteTestArmed {
            guard pipeline.canAcceptClip else {
                session.showError(PipelineError.queueFull.localizedDescription)
                return
            }
            guard let app = NSWorkspace.shared.frontmostApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                session.showError("Focus a text field in another app before testing paste.")
                return
            }
            let target = InsertionTarget(processID: app.processIdentifier,
                                         appName: app.localizedName ?? "App", bundleID: app.bundleIdentifier ?? "")
            pasteTestRequest = PasteTestRequest(text: sampleText, context: DictationContext(target: target))
        }
        session.handle(event)
        if event == .up || event == .cancel { pasteTestRequest = nil }
    }

    private func received(_ audio: RecordedAudio) {
        if let request = pasteTestRequest {
            pasteTestArmed = false
            pasteTestRequest = nil
            pipeline.submit(audio: audio, context: request.context,
                            transcriber: SampleTextProvider(text: request.text))
            if debugRecording {
                Task { [weak self, debugStore] in
                    do { self?.lastRecordingURL = try await debugStore.save(audio) }
                    catch { self?.status = "Debug audio could not be saved." }
                }
            }
            return
        }
        let length = String(format: "%.1f", audio.duration)
        guard debugRecording else {
            status = "Recorded \(length)s in memory; discarded. Enable debug saving to listen back."
            session.completed("Recorded \(length)s · not saved")
            return
        }
        let generation = self.generation
        Task { [weak self, debugStore] in
            do {
                let url = try await debugStore.save(audio)
                guard let self else { return }
                self.lastRecordingURL = url
                guard self.generation == generation else { return }
                self.status = "Saved \(length)s to last-recording.wav."
                self.session.completed("Saved \(length)s · debug WAV")
            } catch {
                guard let self, self.generation == generation else { return }
                self.status = "Could not save debug audio: \(error.localizedDescription)"
                self.session.showError(self.status)
            }
        }
    }

    @objc private func willSleep() {
        pasteTestRequest = nil
        pasteTestArmed = false
        pipeline.cancel()
        session.cancel()
    }

    func stop() {
        permissionTask?.cancel()
        permissionTask = nil
        monitor.stop()
        pipeline.cancel()
        session.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
