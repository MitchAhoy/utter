import AVFoundation
import XCTest
@testable import Utter

final class AudioTests: XCTestCase {
    private func u32(_ data: Data, at offset: Int) -> UInt32 {
        (0..<4).reduce(0) { $0 | UInt32(data[offset + $1]) << ($1 * 8) }
    }
    func testWAVHeaderAndPayload() {
        let data = RecordedAudio(samples: [0, 1, -1, 0.5]).wavData()
        XCTAssertEqual(data.count, 52)
        XCTAssertEqual(String(data: data[0..<4], encoding: .utf8), "RIFF")
        XCTAssertEqual(String(data: data[8..<12], encoding: .utf8), "WAVE")
        XCTAssertEqual(String(data: data[36..<40], encoding: .utf8), "data")
        XCTAssertEqual(u32(data, at: 4), 44)
        XCTAssertEqual(u32(data, at: 24), 16_000)
        XCTAssertEqual(u32(data, at: 28), 32_000)
        XCTAssertEqual(u32(data, at: 40), 8)
        XCTAssertEqual(Array(data[44..<52]), [0, 0, 255, 127, 1, 128, 0, 64])
    }
    func testWAVClampsAndSanitizesNonFiniteSamples() {
        let data = RecordedAudio(samples: [2, -2, .nan, .infinity, -.infinity]).wavData()
        XCTAssertEqual(Array(data[44...]), [255, 127, 1, 128, 0, 0, 0, 0, 0, 0])
    }
    func testEmptyWAVIsValidHeader() {
        let data = RecordedAudio(samples: []).wavData()
        XCTAssertEqual(data.count, 44)
        XCTAssertEqual(u32(data, at: 40), 0)
        XCTAssertEqual(u32(data, at: 4), 36)
    }
    func testDurationUses16kHz() {
        XCTAssertEqual(RecordedAudio(samples: Array(repeating: 0, count: 16000)).duration, 1)
    }
    func test48kStereoConvertsTo16kMono() throws {
        try checkConversion(rate: 48_000, channels: 2)
    }
    func test44kMonoConvertsTo16kMono() throws {
        try checkConversion(rate: 44_100, channels: 1)
    }
    private func checkConversion(rate: Double, channels: AVAudioChannelCount) throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        let store = AudioBufferStore(outputFormat: outputFormat, converter: converter)
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(rate)))
        input.frameLength = input.frameCapacity
        let data = try XCTUnwrap(input.floatChannelData)
        for channel in 0..<Int(channels) {
            for index in 0..<Int(rate) { data[channel][index] = 0.3 * sin(2 * .pi * Float(index) * 440 / Float(rate)) }
        }
        store.append(input)
        store.finishConversion()
        let audio = store.audio()
        XCTAssertNil(store.failure)
        XCTAssertEqual(audio.duration, 1, accuracy: 0.02)
        XCTAssertTrue(audio.samples.allSatisfy(\.isFinite))
        XCTAssertGreaterThan(audio.samples.map { abs($0) }.max() ?? 0, 0.2)
        XCTAssertGreaterThan(store.level, 0)
        XCTAssertLessThanOrEqual(store.level, 1)
    }
    /// AirPods switch from 48 kHz stereo to 24 kHz mono (headset mode) right after recording starts.
    func testStoreFollowsMidRecordingFormatChange() throws {
        let output = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let before = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let after = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000, channels: 1, interleaved: false))
        let store = AudioBufferStore(outputFormat: output, converter: try XCTUnwrap(AVAudioConverter(from: before, to: output)))
        func feed(_ format: AVAudioFormat, seconds: Double) throws {
            let frames = AVAudioFrameCount(format.sampleRate * seconds)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for channel in 0..<Int(format.channelCount) {
                for index in 0..<Int(frames) { channels[channel][index] = 0.3 * sin(Float(index) / 10) }
            }
            store.append(buffer)
        }
        try feed(before, seconds: 0.5)
        try feed(after, seconds: 1)
        store.finishConversion()
        XCTAssertNil(store.failure)
        XCTAssertEqual(store.bufferCount, 2)
        XCTAssertEqual(store.audio().duration, 1.5, accuracy: 0.02)
    }
    func testStreamingConversionRetainsDurationAndPitch() throws {
        let inputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        let outputFormat = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: inputFormat, to: outputFormat))
        let store = AudioBufferStore(outputFormat: outputFormat, converter: converter)
        for chunk in 0..<48 {
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: 1000))
            buffer.frameLength = 1000
            let channels = try XCTUnwrap(buffer.floatChannelData)
            for index in 0..<1000 {
                let sample = Float(0.3) * sin(2 * .pi * Float(chunk * 1000 + index) * 440 / 48_000)
                channels[0][index] = sample
                channels[1][index] = sample
            }
            store.append(buffer)
        }
        store.finishConversion()
        let audio = store.audio()
        XCTAssertNil(store.failure)
        XCTAssertEqual(audio.samples.count, 16_000, accuracy: 2)
        let crossings = zip(audio.samples, audio.samples.dropFirst()).filter { $0.0 < 0 && $0.1 >= 0 }.count
        XCTAssertEqual(crossings, 440, accuracy: 2)
    }
    func testAudioMemoryIsCappedAtFiveMinutes() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let converter = try XCTUnwrap(AVAudioConverter(from: format, to: format))
        let store = AudioBufferStore(outputFormat: format, converter: converter)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = buffer.frameCapacity
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        channel.update(repeating: 0, count: Int(buffer.frameLength))
        for _ in 0..<31 { store.append(buffer) }
        store.finishConversion()
        XCTAssertEqual(store.audio().samples.count, 300 * 16_000)
        XCTAssertNil(store.failure)
    }
    func testDebugSaveReplacesPreviousClip() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DebugRecordingStore(directory: directory)
        let first = try await store.save(RecordedAudio(samples: [0, 1]))
        let second = try await store.save(RecordedAudio(samples: [0.25]))
        XCTAssertEqual(first, second)
        XCTAssertEqual(try Data(contentsOf: second), RecordedAudio(samples: [0.25]).wavData())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["last-recording.wav"])
    }
}
