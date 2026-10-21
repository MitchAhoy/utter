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

    /// Swaps in a converter for a new input format, keeping samples recorded so far.
    func replaceConverter(_ newConverter: AVAudioConverter) {
        lock.lock()
        defer { lock.unlock() }
        drainConverter()
        converter = newConverter
    }

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
    var level: Float { store?.level ?? 0 }
    var failure: String? { configurationFailure ?? store?.failure }

    func start() throws {
        guard engine == nil else { throw RecordingError.message("A recording is already active.") }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw RecordingError.message("Allow microphone access in Utter Settings before recording.")
        }
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
        guard format.sampleRate > 0, format.channelCount > 0,
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: output) else {
            throw RecordingError.message("No usable microphone is connected.")
        }
        let store = AudioBufferStore(outputFormat: output, converter: converter)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTap(store: store))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw RecordingError.message("Could not start the microphone: \(error.localizedDescription)")
        }
        self.store = store
        self.engine = engine
        configurationFailure = nil
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self, weak engine] _ in
            Task { @MainActor [weak self, weak engine] in
                guard let self, let engine, self.engine === engine else { return }
                self.handleConfigurationChange(engine)
            }
        }
    }

    /// macOS posts configuration changes for many harmless reasons, such as
    /// Bluetooth headsets switching to headset mode when recording starts.
    /// Keep recording when nothing changed; otherwise restart on the new format.
    private func handleConfigurationChange(_ engine: AVAudioEngine) {
        guard let store else { return }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        if engine.isRunning && format == store.inputFormat { return }
        input.removeTap(onBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let converter = AVAudioConverter(from: format, to: store.outputFormat) else {
            configurationFailure = "Microphone changed or disconnected. Check the connection and record again."
            return
        }
        store.replaceConverter(converter)
        input.installTap(onBus: 0, bufferSize: 2048, format: format, block: Self.makeTap(store: store))
        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            configurationFailure = "Microphone changed or disconnected. Check the connection and record again."
        }
    }

    // AVAudioNodeTapBlock is non-Sendable. Construct it outside the main actor so
    // Swift does not enforce main-actor isolation on the audio render thread.
    nonisolated private static func makeTap(store: AudioBufferStore) -> AVAudioNodeTapBlock {
        { buffer, _ in store.append(buffer) }
    }

    func stop() throws -> RecordedAudio {
        guard let engine, let store else { throw RecordingError.message("No recording is active.") }
        removeConfigurationObserver()
        let configurationFailure = self.configurationFailure
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        self.engine = nil
        self.store = nil
        store.finishConversion()
        if let configurationFailure { throw RecordingError.message(configurationFailure) }
        if let failure = store.failure { throw RecordingError.message(failure) }
        let audio = store.audio()
        guard !audio.samples.isEmpty else { throw RecordingError.message("No audio received. Check your microphone.") }
        return audio
    }

    private func removeConfigurationObserver() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    func cancel() {
        removeConfigurationObserver()
        configurationFailure = nil
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        engine = nil
        store = nil
    }
}
