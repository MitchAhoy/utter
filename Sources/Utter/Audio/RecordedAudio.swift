import Foundation

struct RecordedAudio: Sendable {
    static let sampleRate = 16_000
    let samples: [Float]
    var duration: TimeInterval { Double(samples.count) / Double(Self.sampleRate) }

    /// Drops quiet lead-in and tail so less audio is uploaded and Whisper has less silence to hallucinate on.
    /// Keeps a short margin around speech, and returns the clip unchanged if nothing is clearly louder than the floor.
    func trimmingSilence(padding: TimeInterval = 0.3) -> RecordedAudio {
        let window = Self.sampleRate / 50
        let count = samples.count / window
        guard count > 10 else { return self }
        let levels = (0..<count).map { index -> Float in
            let slice = samples[(index * window)..<((index + 1) * window)]
            return sqrt(slice.reduce(Float(0)) { $0 + $1 * $1 } / Float(window))
        }
        let sorted = levels.sorted()
        let floor = sorted[count / 10], peak = sorted[count - 1]
        guard peak > floor * 4, peak > 0.003 else { return self }
        let threshold = max(floor * 2, peak * 0.08, 0.002)
        guard let first = levels.firstIndex(where: { $0 > threshold }),
              let last = levels.lastIndex(where: { $0 > threshold }) else { return self }
        let margin = Int(padding * Double(Self.sampleRate))
        let lower = max(0, first * window - margin)
        let upper = min(samples.count, (last + 1) * window + margin)
        guard lower > 0 || upper < samples.count else { return self }
        return RecordedAudio(samples: Array(samples[lower..<upper]))
    }

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
