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
    @Published var mode: DictationMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "dictationMode") }
    }
    @Published var language: String {
        didSet { UserDefaults.standard.set(language, forKey: "dictationLanguage") }
    }
    @Published var microphoneUID: String {
        didSet {
            UserDefaults.standard.set(microphoneUID, forKey: "microphoneUID")
            recorder.selectedDeviceUID = microphoneUID
        }
    }
    @Published private(set) var microphones: [AudioInputDevice] = []
    let localModels = LocalModelController()
    let launchAtLogin = LaunchAtLoginController()
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var microphoneGranted = false
    @Published private(set) var shortcutReady = false
    @Published private(set) var status = "Allow microphone access and enable Accessibility to begin."
    @Published private(set) var lastRecordingURL: URL?
    @Published private(set) var isRecording = false
    @Published var sampleText = "This is a paste test from Utter."
    @Published private(set) var pasteTestArmed = false
    @Published private(set) var isProcessing = false
    private struct CaptureRequest {
        let context: DictationContext
        let provider: any TranscriptionProvider
        let path: DictationPath
    }
    private var captureRequest: CaptureRequest?
    private let pipeline = DictationPipeline(inserter: ClipboardTextInserter())
    private let monitor = EventTapHotkeyMonitor()
    private let debugStore = DebugRecordingStore()
    private let recorder = EngineAudioRecorder()
    private lazy var session = RecordingSession(recorder: recorder, overlay: RecordingOverlay())
    private var permissionTask: Task<Void, Never>?
    private var generation = 0

    init() {
        let defaults = UserDefaults.standard
        mode = DictationMode(rawValue: defaults.string(forKey: "dictationMode") ?? "") ?? .local
        language = defaults.string(forKey: "dictationLanguage") ?? ""
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        sounds = defaults.bool(forKey: "sounds")
        debugRecording = defaults.bool(forKey: "debugRecording")
        monitor.choice = hotkey
        recorder.selectedDeviceUID = microphoneUID
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
                self.session.showProcessing(path: self.pipeline.activePath?.title ?? "")
            case .inserted:
                let sample = self.pipeline.activePath == .sample
                self.status = sample ? "Sample text inserted." : "Dictation inserted · On-device."
                self.session.completed(sample ? "Sample text inserted" : "Inserted · On-device")
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
        refreshMicrophones()
        localModels.prepare(download: false)
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
            captureRequest = nil
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

    var pasteTestActionTitle: String {
        if pasteTestArmed { return "Cancel Paste Test" }
        if !accessibilityGranted { return "Enable Accessibility…" }
        if !microphoneGranted { return "Allow Microphone…" }
        if !shortcutReady { return "Retry Shortcut Monitor" }
        return "Arm Paste Test"
    }

    var pasteTestBlocker: String? {
        if pasteTestArmed { return nil }
        if !accessibilityGranted {
            return "Accessibility is required for pasting. Enable Utter in System Settings → Privacy & Security → Accessibility. After a rebuild, you may need to remove and re-add Utter, then relaunch it."
        }
        if !microphoneGranted {
            return "Microphone access is required to complete the hold-and-release recording test. Click Allow Microphone to grant access."
        }
        if !shortcutReady { return "Shortcut monitoring is not ready. Click Retry Shortcut Monitor." }
        if isRecording { return "Release your shortcut to finish recording before arming a paste test." }
        if isProcessing { return "The previous paste is finishing. The button will be available shortly." }
        return nil
    }

    func togglePasteTest() {
        // Cancelling an armed test must remain possible if permissions change.
        if pasteTestArmed {
            pasteTestArmed = false
            captureRequest = nil
            status = "Paste test cancelled."
            return
        }
        guard !isRecording, !isProcessing else { return }
        refreshPermissions()
        guard accessibilityGranted else {
            status = pasteTestBlocker ?? "Enable Accessibility to test paste."
            openAccessibility()
            return
        }
        guard microphoneGranted else {
            status = pasteTestBlocker ?? "Allow microphone access to test paste."
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                Task { await requestMicrophone() }
            } else {
                openMicrophone()
            }
            return
        }
        guard shortcutReady else { return }
        guard !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            status = "Enter sample text before arming the paste test."
            return
        }
        pasteTestArmed = true
        status = "Paste test armed. Focus a text field in another app, then hold and release your shortcut."
    }

    func refreshMicrophones() { microphones = AudioInputDevices.available() }

    private func handleHotkey(_ event: HotkeyEvent) {
        if event == .down, !session.isRecording {
            captureRequest = nil
            if pasteTestArmed || mode == .local {
                guard pipeline.canAcceptClip else {
                    session.showError(PipelineError.queueFull.localizedDescription)
                    return
                }
                guard pasteTestArmed || localModels.isReady else {
                    session.showError(LocalModelError.notInstalled.localizedDescription)
                    return
                }
                guard let app = NSWorkspace.shared.frontmostApplication,
                      app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
                    session.showError("Focus a text field in another app before dictating.")
                    return
                }
                let target = InsertionTarget(processID: app.processIdentifier,
                                             appName: app.localizedName ?? "App", bundleID: app.bundleIdentifier ?? "")
                let context = DictationContext(target: target, language: language.isEmpty ? nil : language)
                captureRequest = CaptureRequest(context: context,
                                                provider: pasteTestArmed ? SampleTextProvider(text: sampleText) : localModels.provider,
                                                path: pasteTestArmed ? .sample : .local)
            }
        }
        session.handle(event)
        if event == .up || event == .cancel { captureRequest = nil }
    }

    private func received(_ audio: RecordedAudio) {
        if let request = captureRequest {
            if request.path == .sample { pasteTestArmed = false }
            captureRequest = nil
            isProcessing = true
            pipeline.submit(audio: audio, context: request.context, transcriber: request.provider,
                            path: request.path, timeout: .seconds(max(30, audio.duration * 3 + 15)),
                            debugTimings: debugRecording)
            if debugRecording { saveDebugAudio(audio) }
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

    private func saveDebugAudio(_ audio: RecordedAudio) {
        Task { [weak self, debugStore] in
            do { self?.lastRecordingURL = try await debugStore.save(audio) }
            catch { self?.status = "Debug audio could not be saved." }
        }
    }

    @objc private func willSleep() {
        captureRequest = nil
        pasteTestArmed = false
        pipeline.cancel()
        session.cancel()
    }

    func stop() {
        localModels.cancel()
        permissionTask?.cancel()
        permissionTask = nil
        monitor.stop()
        pipeline.cancel()
        session.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
