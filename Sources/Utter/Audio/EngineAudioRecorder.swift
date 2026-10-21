import AVFoundation
import AudioToolbox
import Foundation

@MainActor
protocol AudioRecorder: AnyObject {
    var level: Float { get }
    var failure: String? { get }
    func start() throws
    func stop() throws -> RecordedAudio
    func cancel()
}

/// The render callback and main actor share only this lock-protected buffer.
/// All converter access is serialized under the same lock.
final class AudioBufferStore: @unchecked Sendable {
    private let lock = NSLock()
    private var converter: AVAudioConverter
    let outputFormat: AVAudioFormat
    private var samples: [Float] = []
    private var currentLevel: Float = 0
    private var errorMessage: String?
    private var buffers = 0
    private let maximumSamples = RecordedAudio.sampleRate * 300

    init(outputFormat: AVAudioFormat, converter: AVAudioConverter) {
        self.outputFormat = outputFormat
        self.converter = converter
        samples.reserveCapacity(RecordedAudio.sampleRate * 30)
    }

    func append(_ input: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard samples.count < maximumSamples, errorMessage == nil else { return }
        buffers += 1
        // Bluetooth headsets change format mid-recording; follow whatever the microphone actually delivers.
        if input.format != converter.inputFormat {
            drainConverter()
            guard let adapted = AVAudioConverter(from: input.format, to: outputFormat) else {
                errorMessage = "Microphone audio conversion failed. Try recording again."
                return
            }
            converter = adapted
        }
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate) + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            errorMessage = "Unable to allocate the audio conversion buffer."
            return
        }
        var provided = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            if provided { state.pointee = .noDataNow; return nil }
            provided = true
            state.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.floatChannelData != nil else {
            errorMessage = "Microphone audio conversion failed. Try recording again."
            return
        }
        collect(output)
    }

    /// Drain the resampler's delayed tail so the last syllable is retained.
    func finishConversion() {
        lock.lock()
        defer { lock.unlock() }
        drainConverter()
    }

    var inputFormat: AVAudioFormat { lock.withLock { converter.inputFormat } }

    /// Caller must hold the lock.
    private func drainConverter() {
        while samples.count < maximumSamples && errorMessage == nil {
            guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 4096) else {
                errorMessage = "Unable to finish audio conversion."
                return
            }
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, state in
                state.pointee = .endOfStream
                return nil
            }
            if status == .error || error != nil {
                errorMessage = "Unable to finish audio conversion."
                return
            }
            collect(output)
            if status == .endOfStream || output.frameLength == 0 { return }
        }
    }

    private func collect(_ output: AVAudioPCMBuffer) {
        guard let channel = output.floatChannelData?[0] else { return }
        let count = min(Int(output.frameLength), maximumSamples - samples.count)
        guard count > 0 else { return }
        let buffer = UnsafeBufferPointer(start: channel, count: count)
        samples.append(contentsOf: buffer)
        let rms = sqrt(buffer.reduce(Float(0)) { $0 + $1 * $1 } / Float(count))
        currentLevel = min(1, max(0, (20 * log10(max(rms, 0.0001)) + 60) / 60))
    }

    var level: Float { lock.withLock { currentLevel } }
    /// Audio buffers received so far; used to notice a microphone that stopped delivering.
    var bufferCount: Int { lock.withLock { buffers } }
    var failure: String? { lock.withLock { errorMessage } }
    func audio() -> RecordedAudio { lock.withLock { RecordedAudio(samples: samples) } }
}

@MainActor
final class EngineAudioRecorder: AudioRecorder {
    var selectedDeviceUID = ""
    private var engine: AVAudioEngine?
    private var store: AudioBufferStore?
    private var configurationObserver: NSObjectProtocol?
    private var configurationFailure: String?
    private var watchdog: Task<Void, Never>?
    var level: Float { store?.level ?? 0 }
    var failure: String? { configurationFailure ?? store?.failure }

    func start() throws {
        guard store == nil else { throw RecordingError.message("A recording is already active.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecordingError.message("Allow microphone access in Utter Settings before recording.")
        }
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false) else {
            throw RecordingError.message("No usable microphone is connected.")
        }
        let (engine, format) = try makeEngine()
        guard let converter = AVAudioConverter(from: format, to: output) else {
            throw RecordingError.message("No usable microphone is connected.")
        }
        let store = AudioBufferStore(outputFormat: output, converter: converter)
        try run(engine, format: format, store: store)
        self.store = store
        configurationFailure = nil
        watchAudio(attempt: 0)
    }

    /// A new engine reads the microphone's current hardware format. An existing engine can keep
    /// reporting the old format after a Bluetooth headset switches modes, and then every restart fails.
    private func makeEngine() throws -> (AVAudioEngine, AVAudioFormat) {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        if !selectedDeviceUID.isEmpty {
            guard let device = AudioInputDevices.available().first(where: { $0.id == selectedDeviceUID }),
                  let unit = input.audioUnit else {
                throw RecordingError.message("The selected microphone is unavailable. Choose another microphone in General settings.")
            }
            var id = device.deviceID
            let result = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice,
                                              kAudioUnitScope_Global, 0, &id,
                                              UInt32(MemoryLayout.size(ofValue: id)))
            guard result == noErr else {
                throw RecordingError.message("Could not select the microphone (error \(result)).")
            }
        }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecordingError.message("No usable microphone is connected.")
        }
        return (engine, format)
    }

    /// Taps and starts `engine`, then makes it the active engine and watches it for configuration changes.
    private func run(_ engine: AVAudioEngine, format: AVAudioFormat, store: AudioBufferStore) throws {
        let input = engine.inputNode
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTap(store: store))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecordingError.message("Could not start the microphone: \(error.localizedDescription)")
        }
        self.engine = engine
        removeConfigurationObserver()
        // Matches the engine by identity so the non-Sendable engine never crosses into the closure.
        let engineID = ObjectIdentifier(engine)
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in
            // Delivered on the main queue, so this is already main-actor work.
            MainActor.assumeIsolated {
                guard let self, let current = self.engine, ObjectIdentifier(current) == engineID else { return }
                self.handleConfigurationChange(current)
            }
        }
    }

    /// macOS posts configuration changes for many harmless reasons, such as
    /// Bluetooth headsets switching to headset mode when recording starts.
    /// Keep recording when nothing changed; otherwise reconnect on the new format.
    private func handleConfigurationChange(_ engine: AVAudioEngine) {
        guard let store else { return }
        if engine.isRunning && engine.inputNode.outputFormat(forBus: 0) == store.inputFormat { return }
        reconnect(attempt: 0)
    }

    /// Replaces the engine with a fresh one, keeping everything recorded so far.
    /// The buffer store adapts to the new format when its first buffers arrive.
    private func reconnect(attempt: Int) {
        guard let store else { return }
        if let old = engine {
            removeConfigurationObserver()
            old.stop()
            old.inputNode.removeTap(onBus: 0)
            engine = nil
        }
        do {
            let (fresh, format) = try makeEngine()
            try run(fresh, format: format, store: store)
        } catch {
            // The headset may still be switching; the watchdog tries again shortly.
        }
        watchAudio(attempt: attempt)
    }

    /// Confirms audio is arriving shortly after a (re)start, and reconnects if it is not.
    private func watchAudio(attempt: Int) {
        watchdog?.cancel()
        guard let store else { return }
        let before = store.bufferCount
        watchdog = Task { [weak self, weak store] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, let store, self.store === store, store.bufferCount == before else { return }
            if attempt < 8 {
                self.reconnect(attempt: attempt + 1)
            } else {
                self.configurationFailure = "The microphone stopped sending audio. If you're using AirPods or another Bluetooth headset, try again or choose the built-in microphone in General settings."
            }
        }
    }

    // AVAudioNodeTapBlock is non-Sendable. Construct it outside the main actor so
    // Swift does not enforce main-actor isolation on the audio render thread.
    nonisolated private static func makeTap(store: AudioBufferStore) -> AVAudioNodeTapBlock {
        { buffer, _ in store.append(buffer) }
    }

    func stop() throws -> RecordedAudio {
        guard let store else { throw RecordingError.message("No recording is active.") }
        removeConfigurationObserver()
        watchdog?.cancel(); watchdog = nil
        let configurationFailure = self.configurationFailure
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        self.engine = nil
        self.store = nil
        store.finishConversion()
        if let configurationFailure { throw RecordingError.message(configurationFailure) }
        if let failure = store.failure { throw RecordingError.message(failure) }
        let audio = store.audio()
        guard !audio.samples.isEmpty else { throw RecordingError.message("No audio received. If you're using AirPods or another Bluetooth headset, try again or choose the built-in microphone in General settings.") }
        return audio
    }

    private func removeConfigurationObserver() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    func cancel() {
        removeConfigurationObserver()
        watchdog?.cancel(); watchdog = nil
        configurationFailure = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        store = nil
    }
}
