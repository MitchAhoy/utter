import CoreAudio
import Foundation

/// Apps people take calls in. A browser counts because Google Meet runs in one.
enum CallApps {
    private static let known: [(prefix: String, name: String)] = [
        ("com.google.Chrome", "Google Chrome"), ("com.apple.Safari", "Safari"), ("com.apple.WebKit", "Safari"),
        ("company.thebrowser.Browser", "Arc"), ("company.thebrowser.dia", "Dia"), ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"), ("com.brave.Browser", "Brave"), ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams", "Microsoft Teams"), ("com.tinyspeck.slackmacgap", "Slack"), ("com.apple.FaceTime", "FaceTime"),
        ("com.apple.avconferenced", "FaceTime"), ("net.whatsapp.WhatsApp", "WhatsApp"), ("com.hnc.Discord", "Discord"),
        ("com.cisco.webexmeetingsapp", "Webex"), ("Cisco-Systems.Spark", "Webex"), ("com.openai.chat", "ChatGPT"),
    ]
    /// The app's display name when `bundleID` (or one of its helper processes) is a known call app.
    static func name(for bundleID: String) -> String? {
        known.first { bundleID.lowercased().hasPrefix($0.prefix.lowercased()) }?.name
    }
}

/// Decides when to offer note-taking and when a recorded call has ended, from which call apps hold the microphone.
struct MeetingDetection: Sendable {
    enum Event: Equatable, Sendable {
        case offer(app: String)
        case callEnded
    }
    /// The microphone must be held this long first, so a voice search or a mic test does not prompt.
    var settle: TimeInterval = 4
    /// After the microphone is released for this long the call is over.
    var release: TimeInterval = 12

    private var app: String?
    private var since: Date?
    private var lastSeen: Date?
    private var offered = false
    private var sawCallWhileRecording = false
    private var wasRecording = false

    init() {}

    /// `callApps` are the names of call apps using the microphone right now.
    mutating func update(callApps: [String], recording: Bool, now: Date) -> Event? {
        if recording != wasRecording {
            wasRecording = recording
            sawCallWhileRecording = false
        }
        if let current = callApps.first {
            if app == nil { app = current; since = now; offered = false }
            lastSeen = now
            if recording {
                sawCallWhileRecording = true
                offered = true
            } else if !offered, let since, now.timeIntervalSince(since) >= settle {
                offered = true
                return .offer(app: app ?? current)
            }
            return nil
        }
        guard let lastSeen, now.timeIntervalSince(lastSeen) >= release else { return nil }
        app = nil; since = nil; self.lastSeen = nil; offered = false
        if recording && sawCallWhileRecording {
            sawCallWhileRecording = false
            return .callEnded
        }
        return nil
    }
}

/// Reads from Core Audio which other apps are recording from a microphone.
enum MicrophoneUsers {
    static func callApps() -> [String] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &bytes) == noErr, bytes > 0 else { return [] }
        var processes = Array(repeating: AudioObjectID(0), count: Int(bytes) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &bytes, &processes) == noErr else { return [] }
        let own = ProcessInfo.processInfo.processIdentifier
        var names: [String] = []
        for process in processes {
            var running: UInt32 = 0
            guard read(process, kAudioProcessPropertyIsRunningInput, &running), running != 0 else { continue }
            var pid: pid_t = 0
            guard read(process, kAudioProcessPropertyPID, &pid), pid != own else { continue }
            var bundle: CFString = "" as CFString
            guard read(process, kAudioProcessPropertyBundleID, &bundle),
                  let name = CallApps.name(for: bundle as String), !names.contains(name) else { continue }
            names.append(name)
        }
        return names.sorted()
    }

    private static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ value: inout T) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var bytes = UInt32(MemoryLayout<T>.size)
        return withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &bytes, $0) } == noErr
    }
}
