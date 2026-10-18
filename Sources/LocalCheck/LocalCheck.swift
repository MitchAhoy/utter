import AVFoundation
import Foundation

/// Reproducible integration check using synthetic speech, with no microphone or paste events.
@main
struct LocalCheck {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count >= 3, let model = LocalModel(rawValue: args[0]) else {
            print("Usage: UtterLocalCheck <small|largeTurbo> <model-storage-directory> <audio-file> [--download]")
            return
        }
        let engine = WhisperKitProvider(store: LocalModelStore(root: URL(fileURLWithPath: args[1], isDirectory: true)))
        try await engine.prepare(model, allowDownload: args.contains("--download")) { fraction, stage in
            if let fraction { print("\(Int(fraction * 100))% \(stage)") }
            else { print(stage) }
        }
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: args[2]))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: format),
              let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 4096) else {
            throw RecordingError.message("Unable to read the synthetic test fixture.")
        }
        try file.read(into: buffer)
        var sent = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if sent { status.pointee = .endOfStream; return nil }
            sent = true
            status.pointee = .haveData
            return buffer
        }
        if let conversionError { throw conversionError }
        guard let channel = output.floatChannelData?[0] else { throw LocalModelError.noSpeech }
        let audio = RecordedAudio(samples: Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength))))
        let started = ContinuousClock.now
        let transcript = try await engine.transcribe(audio: audio, language: "en", prompt: nil)
        let normalized = transcript.lowercased()
        guard ["quick", "brown", "fox", "lazy", "dog"].allSatisfy(normalized.contains) else {
            throw RecordingError.message("Synthetic speech check failed: expected phrase keywords were not recognized.")
        }
        print("PASS: local model recognized synthetic speech from in-memory 16 kHz audio (\(started.duration(to: .now))).")
        do {
            _ = try await engine.transcribe(audio: RecordedAudio(samples: Array(repeating: 0, count: 16_000)), language: "en", prompt: nil)
            throw RecordingError.message("Silence unexpectedly produced a transcript.")
        } catch LocalModelError.noSpeech {
            print("PASS: silence does not generate dictation.")
        }
    }
}
