import Foundation

/// A stretch of speech cut from a long recording, with where it began in the meeting.
struct SpeechChunk: Sendable {
    let start: TimeInterval
    let audio: RecordedAudio
}

/// Cuts a continuous 16 kHz stream into chunks at pauses, so a meeting can be transcribed while it runs.
///
/// Silence is never emitted. Chunks are kept long enough to stay within Groq's requests-per-minute
/// allowance and short enough that the transcript appears while people are still talking.
struct SpeechSegmenter: Sendable {
    /// A pause this long always ends the chunk.
    var longPause: TimeInterval = 2.0
    /// Once a chunk is at least `preferredLength`, this shorter pause ends it.
    var shortPause: TimeInterval = 0.6
    var preferredLength: TimeInterval = 8
    /// Past this length, the first brief gap between words ends the chunk.
    var softLimit: TimeInterval = 20
    var briefGap: TimeInterval = 0.24
    /// A chunk is cut here even mid-sentence.
    var hardLimit: TimeInterval = 30
    /// Chunks with less speech than this are noise (a click, a cough) and are dropped.
    var minimumSpeech: TimeInterval = 0.3
    /// Quiet audio kept on each side of speech so word edges are not clipped.
    var padding: TimeInterval = 0.3

    private static let frame = RecordedAudio.sampleRate / 50
    private static let frameTime = 1.0 / 50
    private var pending: [Float] = []
    /// Recent quiet audio, kept so a chunk can start slightly before the first loud frame.
    private var lead: [Float] = []
    private var chunk: [Float] = []
    private var chunkStart: TimeInterval = 0
    private var speechFrames = 0
    private var quietFrames = 0
    private var active = false
    private var consumed = 0
    private var base: TimeInterval = 0
    private var floor: Float = 0.002

    init() {}

    private var now: TimeInterval { base + Double(consumed) / Double(RecordedAudio.sampleRate) }

    mutating func append(_ samples: [Float]) -> [SpeechChunk] {
        pending.append(contentsOf: samples)
        var result: [SpeechChunk] = []
        var offset = 0
        while pending.count - offset >= Self.frame {
            let slice = pending[offset..<(offset + Self.frame)]
            offset += Self.frame
            if let finished = process(slice) { result.append(finished) }
        }
        pending.removeFirst(offset)
        return result
    }

    /// Ends the stream, returning speech still in progress.
    mutating func finish() -> [SpeechChunk] {
        pending.removeAll()
        lead.removeAll()
        return close().map { [$0] } ?? []
    }

    /// After a gap in capture (a device change), continues from `time` so later chunks stay aligned with the meeting clock.
    mutating func resync(to time: TimeInterval) -> [SpeechChunk] {
        let result = finish()
        base = max(time, now)
        consumed = 0
        return result
    }

    private mutating func process(_ slice: ArraySlice<Float>) -> SpeechChunk? {
        let energy = slice.reduce(Float(0)) { $0 + ($1.isFinite ? $1 * $1 : 0) }
        let level = (energy / Float(Self.frame)).squareRoot()
        // Follows the room's background noise: drops quickly, rises slowly.
        floor = level < floor ? max(level, 0.0002) : floor + (min(level, 0.02) - floor) * 0.002
        let speech = level > max(0.004, floor * 3)
        let frameStart = now
        consumed += Self.frame
        guard active else {
            if speech {
                active = true
                chunkStart = frameStart - Double(lead.count) / Double(RecordedAudio.sampleRate)
                chunk = lead
                chunk.append(contentsOf: slice)
                lead.removeAll(keepingCapacity: true)
                speechFrames = 1
                quietFrames = 0
            } else {
                lead.append(contentsOf: slice)
                let limit = Int(padding * Double(RecordedAudio.sampleRate))
                if lead.count > limit { lead.removeFirst(lead.count - limit) }
            }
            return nil
        }
        chunk.append(contentsOf: slice)
        if speech { speechFrames += 1; quietFrames = 0 } else { quietFrames += 1 }
        let length = Double(chunk.count) / Double(RecordedAudio.sampleRate)
        let quiet = Double(quietFrames) * Self.frameTime
        let ended = quiet >= longPause
            || (length >= preferredLength && quiet >= shortPause)
            || (length >= softLimit && quiet >= briefGap)
            || length >= hardLimit
        return ended ? close() : nil
    }

    private mutating func close() -> SpeechChunk? {
        guard active else { return nil }
        active = false
        // Keep only a short tail of the closing pause.
        let keptQuiet = min(quietFrames, Int(padding / Self.frameTime))
        chunk.removeLast(min(chunk.count, (quietFrames - keptQuiet) * Self.frame))
        defer { chunk = []; speechFrames = 0; quietFrames = 0 }
        guard Double(speechFrames) * Self.frameTime >= minimumSpeech else { return nil }
        return SpeechChunk(start: max(0, chunkStart), audio: RecordedAudio(samples: chunk))
    }
}
