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
    let features = FeatureSettings()
    let cloud: CloudSettings
    let updates = UpdateController()
    private let historyStore: HistoryStore
    lazy var history = HistoryController(settings: features, store: historyStore)
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
        let cleaner: any CleanupProvider
        var selection: Task<String, Error>? = nil
        var editor: (any CommandProvider)? = nil
    }
    private var captureRequest: CaptureRequest?
    private let pipeline = DictationPipeline(inserter: ClipboardTextInserter())
    private let monitor = EventTapHotkeyMonitor()
    private let debugStore = DebugRecordingStore()
    private let recorder = EngineAudioRecorder()
    private lazy var session = RecordingSession(recorder: recorder, overlay: RecordingOverlay())
    private var permissionTask: Task<Void, Never>?
    private var generation = 0
    private var commandRecording = false
    private var commandShortcutActive = false

    init(cloud: CloudSettings = CloudSettings(), historyStore: HistoryStore = HistoryStore()) {
        self.cloud = cloud
        self.historyStore = historyStore
        let defaults = UserDefaults.standard
        mode = DictationMode(rawValue: defaults.string(forKey: "dictationMode") ?? "") ?? .local
        language = defaults.string(forKey: "dictationLanguage") ?? ""
        microphoneUID = defaults.string(forKey: "microphoneUID") ?? ""
        hotkey = HotkeyChoice(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption
        sounds = defaults.bool(forKey: "sounds")
        debugRecording = defaults.bool(forKey: "debugRecording")
        monitor.choice = hotkey
        recorder.selectedDeviceUID = microphoneUID
        session.onError = { [weak self] message in self?.status = message }
        localModels.onReady = { [weak self] in self?.status = "Ready · On-device — hold your shortcut to dictate." }
        cloud.onDisabled = { [weak self] in self?.pipeline.cancel() }
        KeyboardShortcuts.onKeyDown(for: .editSelection) { [weak self] in self?.handleCommandKey(down: true) }
        KeyboardShortcuts.onKeyUp(for: .editSelection) { [weak self] in self?.handleCommandKey(down: false) }
        KeyboardShortcuts.disable(.editSelection)
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
        pipeline.onResult = { [weak self] raw, cleaned, context, path in
            self?.history.record(raw: raw, cleaned: cleaned, context: context, path: path)
        }
        pipeline.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case .processing:
                self.isProcessing = true
                self.session.showProcessing(path: self.pipeline.activePath?.title ?? "")
            case .inserted:
                let sample = self.pipeline.activePath == .sample
                self.status = sample ? "Sample text inserted." : "Inserted · \(self.pipeline.activePath?.title ?? "Dictation")"
                self.session.completed(sample ? "Sample text inserted" : "Inserted · \(self.pipeline.activePath?.title ?? "Dictation")")
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
        cloud.refreshKeys()
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
        refreshCommandShortcut()
        if !microphoneGranted && session.isRecording {
            captureRequest?.selection?.cancel()
            commandRecording = false
            captureRequest = nil
            session.cancel()
            session.showError("Microphone access was revoked. Allow access in System Settings.")
        }
        if !accessibilityGranted {
            captureRequest?.selection?.cancel()
            captureRequest = nil
            commandRecording = false
            session.cancel()
            if shortcutReady { monitor.stop() }
            pipeline.cancel()
            shortcutReady = false
            status = "Enable this copy of Utter in Accessibility under Permissions to use the shortcut and paste."
            return
        }
        if shortcutReady && monitor.isRunning { return }
        if shortcutReady { monitor.stop(); shortcutReady = false }
        do {
            try monitor.start { [weak self] event in self?.handleHotkey(event) }
            shortcutReady = true
            status = microphoneGranted ? (mode == .local && !localModels.isReady
                ? "Prepare a speech model in Transcription settings to start dictation."
                : "Ready — hold your shortcut to record.") : "Allow microphone access to record."
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

    func retryHotkeyMonitor() {
        monitor.stop()
        shortcutReady = false
        refreshPermissions()
    }

    func refreshCommandShortcut() {
        let enabled = features.commandEnabled && accessibilityGranted
        guard enabled != commandShortcutActive else { return }
        commandShortcutActive = enabled
        if enabled { KeyboardShortcuts.enable(.editSelection) }
        else { KeyboardShortcuts.disable(.editSelection) }
    }

    private func makeCapture(command: Bool = false) throws -> CaptureRequest {
        guard pipeline.canAcceptClip else { throw PipelineError.queueFull }
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            throw RecordingError.message("Focus a text field in another app before dictating.")
        }
        let provider: any TranscriptionProvider
        let path: DictationPath
        if pasteTestArmed && !command {
            provider = SampleTextProvider(text: sampleText); path = .sample
        } else {
            switch mode {
            case .local, .recordingOnly:
                guard localModels.isReady else { throw LocalModelError.notInstalled }
                provider = localModels.provider; path = .local
            case .cloud:
                guard cloud.enabled else { throw CloudError.disabled }
                guard cloud.storedKeys.contains(cloud.provider.service) else { throw CloudError.missingKey(cloud.provider.service) }
                provider = cloud.transcriber(); path = .cloud
            case .auto:
                let remote = cloud.enabled && cloud.storedKeys.contains(cloud.provider.service) ? cloud.transcriber() : nil
                guard remote != nil || localModels.isReady else { throw LocalModelError.notInstalled }
                provider = RoutedTranscriptionProvider(cloud: remote, local: localModels.isReady ? localModels.provider : nil,
                                                       allowFallback: true)
                path = .auto
            }
        }
        let target = InsertionTarget(processID: app.processIdentifier, appName: app.localizedName ?? "App", bundleID: app.bundleIdentifier ?? "")
        let terms = features.terms
        let context = DictationContext(target: target, language: language.isEmpty ? nil : language,
                                       prompt: terms.isEmpty ? nil : terms.joined(separator: ", "), dictionary: terms,
                                       style: features.style(for: target.bundleID))
        return CaptureRequest(context: context, provider: provider, path: command ? .command : path,
                              cleaner: path == .sample ? PassthroughProvider() : cloud.cleaner())
    }

    private func handleHotkey(_ event: HotkeyEvent) {
        if commandRecording && event != .cancel { return }
        if event == .cancel { commandRecording = false; captureRequest?.selection?.cancel() }
        if event == .down, !session.isRecording {
            captureRequest = nil
            if pasteTestArmed || mode != .recordingOnly {
                do { captureRequest = try makeCapture() }
                catch { session.showError(error.localizedDescription); return }
            }
        }
        session.handle(event)
        if event == .up || event == .cancel {
            captureRequest?.selection?.cancel()
            captureRequest = nil
        }
    }

    private func handleCommandKey(down: Bool) {
        if !down {
            guard commandRecording else { return }
            session.handle(.up)
            captureRequest?.selection?.cancel()
            captureRequest = nil
            commandRecording = false
            return
        }
        guard features.commandEnabled, !session.isRecording, !commandRecording else { return }
        do {
            guard cloud.enabled else { throw CloudError.disabled }
            guard cloud.storedKeys.contains(.anthropic) else { throw CloudError.missingKey(.anthropic) }
            var request = try makeCapture(command: true)
            let target = request.context.target
            request.selection = Task { try await ClipboardSelectionReader().read(target: target) }
            request.editor = cloud.claude(timeout: 30)
            captureRequest = request
            commandRecording = true
            session.handle(.down)
        } catch { session.showError(error.localizedDescription) }
    }

    private func received(_ audio: RecordedAudio) {
        if let request = captureRequest {
            if request.path == .sample { pasteTestArmed = false }
            captureRequest = nil
            isProcessing = true
            pipeline.submit(audio: audio, context: request.context, transcriber: request.provider,
                            path: request.path, timeout: .seconds(max(30, audio.duration * 3 + 15)),
                            debugTimings: debugRecording, cleaner: request.cleaner,
                            cleanupLimit: .seconds(max(0.2, cloud.cleanupTimeout)), transforms: features.transforms,
                            selection: request.selection, editor: request.editor)
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
        captureRequest?.selection?.cancel()
        captureRequest = nil
        commandRecording = false
        pasteTestArmed = false
        pipeline.cancel()
        session.cancel()
    }

    func stop() {
        localModels.cancel()
        permissionTask?.cancel()
        permissionTask = nil
        KeyboardShortcuts.disable(.editSelection)
        captureRequest?.selection?.cancel()
        monitor.stop()
        pipeline.cancel()
        session.cancel()
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }
}
