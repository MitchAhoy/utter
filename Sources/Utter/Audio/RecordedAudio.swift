import Foundation

struct RecordedAudio: Sendable {
    static let sampleRate = 16_000
    let samples: [Float]
    var duration: TimeInterval { Double(samples.count) / Double(Self.sampleRate) }

    /// Standard little-endian PCM16 WAV. Float samples remain in memory until encoded.
    func wavData() -> Data {
        let byteCount = UInt32(samples.count * 2)
        var result = Data()
        func text(_ value: String) { result.append(contentsOf: value.utf8) }
        func word<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { result.append(contentsOf: $0) }
        }
        text("RIFF"); word(byteCount + 36); text("WAVE")
        text("fmt "); word(UInt32(16)); word(UInt16(1)); word(UInt16(1))
        word(UInt32(Self.sampleRate)); word(UInt32(Self.sampleRate * 2))
        word(UInt16(2)); word(UInt16(16)); text("data"); word(byteCount)
        for sample in samples {
            let finite = sample.isFinite ? sample : 0
            let clamped = max(-1, min(1, finite))
            word(Int16((clamped * Float(Int16.max)).rounded()))
        }
        return result
    }
}

enum RecordingError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): text }
    }
}
