import AVFoundation
import Foundation

/// End-to-end check of meeting notes against the live services: a scripted two-voice call is synthesised,
/// cut into chunks, transcribed, turned into notes and questioned. Run with GROQ_API_KEY set.
@main
struct MeetingCheck {
    static let script: [(Speaker, String)] = [
        (.them, "Thanks for joining. I want to walk through the launch plan for the new booking app."),
        (.me, "Sounds good. Where are we with the pricing page?"),
        (.them, "The pricing page is not finished. Priya needs the final copy from you before she can publish it."),
        (.me, "Okay. I will send Priya the final pricing copy by Thursday."),
        (.them, "Great. The second thing is the contract with the payments provider. Legal has not reviewed it yet."),
        (.me, "I can chase that. I will ask legal to review the payments contract this week."),
        (.them, "Perfect. On my side, I will record a demo video for the sales team and share it on Monday."),
        (.me, "That works. Did we decide which city to launch in first?"),
        (.them, "Yes. We agreed to launch in Brisbane first, and then Melbourne a month later."),
        (.me, "Good. And who is handling customer support during launch week?"),
        (.them, "Marcus is covering support for launch week, with Elena as the backup."),
        (.me, "Excellent. I think that covers everything. Talk to you next week."),
    ]
    /// Each planted action item, as words the notes must contain.
    static let actions: [[String]] = [["priya", "thursday"], ["legal", "contract"], ["demo", "monday"]]
    static let questions: [(String, [String])] = [
        ("Which city are we launching in first?", ["brisbane"]),
        ("Who is covering customer support during launch week?", ["marcus"]),
        ("What do I need to send Priya, and by when?", ["pricing", "thursday"]),
        ("Who is the backup for support?", ["elena"]),
        ("When will the demo video be shared?", ["monday"]),
    ]
    static let unanswerable = ["What is the marketing budget for the launch?", "Which designer is making the logo?"]

    static func main() async throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        guard let key = ProcessInfo.processInfo.environment["GROQ_API_KEY"], !key.isEmpty else {
            print("SKIP: set GROQ_API_KEY; no live API calls made.")
            return
        }
        var failures = 0
        func check(_ passed: Bool, _ label: String) {
            print("\(passed ? "PASS" : "FAIL")  \(label)")
            if !passed { failures += 1 }
        }

        // 1. Synthesise the call: each voice on its own channel, silent while the other speaks.
        var streams: [Speaker: [Float]] = [.me: [], .them: []]
        var timeline: [(speaker: Speaker, start: Double, end: Double)] = []
        for (speaker, text) in script {
            let voice = try speak(text, voice: speaker == .me ? "Samantha" : "Daniel")
            let start = Double(streams[speaker]!.count) / 16_000
            let gap = [Float](repeating: 0, count: 16_000)
            for channel in [Speaker.me, .them] {
                streams[channel]! += (channel == speaker ? voice : [Float](repeating: 0, count: voice.count)) + gap
            }
            timeline.append((speaker, start, start + Double(voice.count) / 16_000))
        }
        let length = Double(streams[.me]!.count) / 16_000
        print("Synthesised a \(Int(length)) second call with \(script.count) turns.")

        // 2. Cut into chunks exactly as the recorder does, a quarter second at a time.
        var chunks: [(Speaker, SpeechChunk)] = []
        for speaker in [Speaker.me, .them] {
            var segmenter = SpeechSegmenter()
            let samples = streams[speaker]!
            var index = 0
            while index < samples.count {
                let end = min(samples.count, index + 4_000)
                chunks += segmenter.append(Array(samples[index..<end])).map { (speaker, $0) }
                index = end
            }
            chunks += segmenter.finish().map { (speaker, $0) }
        }
        check(chunks.allSatisfy { $0.1.audio.duration <= 30.01 }, "no chunk is longer than 30 seconds (\(chunks.count) chunks)")

        // 3. Transcribe.
        let transcriber = MeetingTranscriber(primary: CloudTranscriptionProvider(provider: .groq, authorize: { key }), language: "en")
        var segments: [TranscriptSegment] = []
        let began = ContinuousClock.now
        for (speaker, chunk) in chunks {
            if let text = try await transcriber.text(for: chunk) {
                segments.append(TranscriptSegment(id: Int64(segments.count + 1), meeting: "check", speaker: speaker, start: chunk.start, text: text))
            }
        }
        segments.sort { $0.start < $1.start }
        print("Transcribed in \(began.duration(to: .now).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))):")
        print(MeetingAssistant.transcript(segments))

        // 4. Every line is on the right side, and the words are right.
        let misplaced = segments.filter { segment in
            timeline.first { segment.start + 0.5 >= $0.start - 0.5 && segment.start + 0.5 <= $0.end }?.speaker != segment.speaker
        }
        check(misplaced.isEmpty, "every line is attributed to the side that spoke it")
        for speaker in [Speaker.me, .them] {
            let expected = words(script.filter { $0.0 == speaker }.map(\.1).joined(separator: " "))
            let heard = words(segments.filter { $0.speaker == speaker }.map(\.text).joined(separator: " "))
            let rate = Double(distance(expected, heard)) / Double(expected.count)
            check(rate < 0.10, "\(speaker.title): word error rate \(String(format: "%.1f", rate * 100))% (limit 10%)")
        }

        // 5. Enhanced notes hold every planted action item, and every time in them is real.
        let model = ProcessInfo.processInfo.environment["GROQ_MODEL"] ?? MeetingAssistant.defaultModel
        print("\nNotes and answers from \(model).")
        let assistant = MeetingAssistant(provider: GroqCleanupProvider(model: model, timeout: 60, authorize: { key }))
        let meeting = Meeting(id: "check", title: "Launch plan", started: Date(), notes: "pricing page - what do I owe?")
        let noteStart = ContinuousClock.now
        let notes = try await assistant.notes(meeting: meeting, segments: segments, template: .general)
        print("\nNotes written in \(noteStart.duration(to: .now).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))):\n\(notes)\n")
        let lower = notes.lowercased()
        for action in actions { check(action.allSatisfy(lower.contains), "notes include the action item: \(action.joined(separator: " + "))") }
        check(lower.contains("## "), "notes use section headings")
        let times = notes.matches(of: /\[(\d{1,2}:\d{2})\]/).compactMap { MeetingAssistant.seconds(String($0.1)) }
        check(!times.isEmpty && times.allSatisfy { $0 <= length + 30 }, "notes cite \(times.count) times, all inside the meeting")

        // 6. Questions: answered from the meeting, and refused when the meeting does not say.
        for (question, expected) in questions {
            let answer = try await assistant.answer(question: question, meeting: meeting, segments: segments)
            check(expected.allSatisfy(answer.lowercased().contains), "\(question) → \(answer.replacingOccurrences(of: "\n", with: " "))")
        }
        for question in unanswerable {
            let answer = try await assistant.answer(question: question, meeting: meeting, segments: segments)
            check(answer.contains(MeetingAssistant.notDiscussed), "\(question) → \(answer.replacingOccurrences(of: "\n", with: " "))")
        }
        print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    /// Speech from the macOS `say` command as 16 kHz mono samples.
    static func speak(_ text: String, voice: String) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appending(path: "utter-check-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-v", voice, "-o", url.path, "--data-format=LEI16@16000", text]
        try process.run()
        process.waitUntilExit()
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else { return [] }
        try file.read(into: buffer)
        guard let channel = buffer.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "okay", with: "ok").split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Word-level edit distance.
    static func distance(_ first: [String], _ second: [String]) -> Int {
        var row = Array(0...second.count)
        for (i, word) in first.enumerated() {
            var previous = row[0]
            row[0] = i + 1
            for (j, other) in second.enumerated() {
                let current = row[j + 1]
                row[j + 1] = min(previous + (word == other ? 0 : 1), row[j] + 1, current + 1)
                previous = current
            }
        }
        return row[second.count]
    }
}
