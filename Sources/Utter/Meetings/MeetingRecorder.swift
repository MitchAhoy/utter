import AVFoundation
import CoreAudio

/// Supplies a meeting's speech as it happens. A protocol so the controller can be tested without audio hardware.
@MainActor
protocol MeetingCapturing: AnyObject {
    var onChunk: (@MainActor (Speaker, SpeechChunk) -> Void)? { get set }
    /// While true the microphone is ignored, so dictation spoken during a call stays out of the transcript.
    var microphonePaused: Bool { get set }
    /// Set once any sound from the Mac's output has been captured.
    var heardSystemAudio: Bool { get }
    func start(microphoneUID: String, offset: TimeInterval) throws
    /// Stops capture and delivers any speech still in progress.
    func stop()
}

/// Records the microphone ("Me") and the Mac's audio output ("Them") side by side and cuts both into speech chunks.
/// Audio lives in memory only until it has been cut into chunks.
@MainActor
final class MeetingRecorder: MeetingCapturing {
    var onChunk: (@MainActor (Speaker, SpeechChunk) -> Void)?
    var microphonePaused = false
    private(set) var heardSystemAudio = false

    private var microphone: DeviceInputCapture?
    private var microphoneStore: AudioBufferStore?
    private var microphoneUID = ""
    private var followsDefaultInput = false
    private var tap: SystemAudioTap?
    private var tapStore: AudioBufferStore?
    private var outputDevice = AudioDeviceID(kAudioObjectUnknown)
    private var segmenters: [Speaker: SpeechSegmenter] = [:]
    private var bufferCounts: [Speaker: Int] = [:]
    private var microphoneWasPaused = false
    private var pump: Task<Void, Never>?
    private var began = ContinuousClock.now
    private var offset: TimeInterval = 0
    private var ticks = 0

    private static let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(RecordedAudio.sampleRate),
                                              channels: 1, interleaved: false)

    private var elapsed: TimeInterval {
        let passed = ContinuousClock.now - began
        return offset + Double(passed.components.seconds) + Double(passed.components.attoseconds) / 1e18
    }

    func start(microphoneUID: String, offset: TimeInterval) throws {
        guard pump == nil else { throw MeetingError.alreadyRecording }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecordingError.message("Allow microphone access in Utter Settings before recording a meeting.")
        }
        followsDefaultInput = microphoneUID.isEmpty
        self.microphoneUID = microphoneUID
        self.offset = offset
        began = .now
        heardSystemAudio = false
        microphoneWasPaused = false
        ticks = 0
        segmenters = [:]
        for speaker in [Speaker.me, .them] {
            var segmenter = SpeechSegmenter()
            _ = segmenter.resync(to: offset)
            segmenters[speaker] = segmenter
        }
        do {
            try openTap()
            try openMicrophone()
        } catch {
            closeCaptures()
            throw error
        }
        pump = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self?.tick()
            }
        }
    }

    func stop() {
        guard pump != nil else { return }
        pump?.cancel()
        pump = nil
        microphoneStore?.finishConversion()
        tapStore?.finishConversion()
        drain()
        closeCaptures()
        for speaker in [Speaker.me, .them] {
            for chunk in segmenters[speaker]?.finish() ?? [] { onChunk?(speaker, chunk) }
        }
        segmenters = [:]
    }

    private func makeStore(from format: AVAudioFormat) throws -> AudioBufferStore {
        guard let output = Self.output, let converter = AVAudioConverter(from: format, to: output) else {
            throw RecordingError.message("Audio conversion is unavailable.")
        }
        return AudioBufferStore(outputFormat: output, converter: converter, maximumSamples: RecordedAudio.sampleRate * 120)
    }

    private func openTap() throws {
        let tap = try SystemAudioTap()
        let store = try tapStore ?? makeStore(from: tap.format)
        try tap.start(store: store)
        self.tap = tap
        tapStore = store
        outputDevice = AudioInputDevices.defaultOutputID()
    }

    private func openMicrophone() throws {
        if followsDefaultInput { microphoneUID = AudioInputDevices.defaultInput()?.id ?? "" }
        let capture = try DeviceInputCapture(uid: microphoneUID)
        let store = try microphoneStore ?? makeStore(from: capture.format)
        try capture.start(store: store)
        microphone = capture
        microphoneStore = store
    }

    private func closeCaptures() {
        microphone?.stop(); microphone = nil; microphoneStore = nil
        tap?.stop(); tap = nil; tapStore = nil
    }

    private func tick() {
        drain()
        ticks += 1
        if ticks % 12 == 0 { repairCaptures() }
    }

    /// Moves converted audio into the segmenters and passes on any finished chunks.
    private func drain() {
        if let samples = tapStore?.drain(), !samples.isEmpty {
            if !heardSystemAudio { heardSystemAudio = samples.contains { abs($0) > 0.0005 } }
            emit(.them, segmenters[.them]?.append(samples) ?? [])
        }
        if let samples = microphoneStore?.drain(), !samples.isEmpty {
            if microphonePaused {
                microphoneWasPaused = true
            } else {
                if microphoneWasPaused {
                    microphoneWasPaused = false
                    emit(.me, segmenters[.me]?.resync(to: elapsed) ?? [])
                }
                emit(.me, segmenters[.me]?.append(samples) ?? [])
            }
        }
    }

    private func emit(_ speaker: Speaker, _ chunks: [SpeechChunk]) {
        for chunk in chunks { onChunk?(speaker, chunk) }
    }

    /// Every three seconds: reopen a capture that stopped delivering, or whose device changed
    /// (headphones connected, microphone unplugged), and realign its clock.
    private func repairCaptures() {
        let tapCount = tapStore?.bufferCount ?? 0
        if tap == nil || tapCount == bufferCounts[.them] || outputDevice != AudioInputDevices.defaultOutputID() {
            tap?.stop(); tap = nil
            try? openTap()
            emit(.them, segmenters[.them]?.resync(to: elapsed) ?? [])
        }
        bufferCounts[.them] = tapStore?.bufferCount ?? 0
        let microphoneCount = microphoneStore?.bufferCount ?? 0
        let inputMoved = followsDefaultInput && AudioInputDevices.defaultInput().map { $0.id != microphoneUID } == true
        if microphone == nil || microphoneCount == bufferCounts[.me] || inputMoved {
            microphone?.stop(); microphone = nil
            try? openMicrophone()
            emit(.me, segmenters[.me]?.resync(to: elapsed) ?? [])
        }
        bufferCounts[.me] = microphoneStore?.bufferCount ?? 0
    }
}
