import AVFoundation
import CoreAudio

/// Captures what the Mac is playing (the other people in a call) with a Core Audio process tap.
///
/// Nothing joins the call and playback is unaffected. macOS asks once for "System Audio Recording"
/// permission; without it the tap still starts but delivers silence.
final class SystemAudioTap: @unchecked Sendable {
    let format: AVAudioFormat
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "org.utter.system-audio", qos: .userInitiated)
    private var disposed = false

    init() throws {
        // Everything the Mac plays except Utter's own sounds, mixed to one channel.
        let description = CATapDescription(monoGlobalTapButExcludeProcesses: Self.ownProcessObject().map { [$0] } ?? [])
        description.uuid = UUID()
        description.name = "Utter meeting audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        var tap = AudioObjectID(kAudioObjectUnknown)
        try Self.check(AudioHardwareCreateProcessTap(description, &tap), "create the system audio tap")
        tapID = tap
        do {
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat, mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            var stream = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &stream), "read the system audio format")
            guard stream.mSampleRate > 0, let format = AVAudioFormat(streamDescription: &stream) else {
                throw RecordingError.message("System audio is unavailable.")
            }
            self.format = format
            // A tap is read through a private aggregate device that contains only the tap.
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Utter meeting audio",
                kAudioAggregateDeviceUIDKey: "org.utter.meeting-audio.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                   kAudioSubTapDriftCompensationKey: true]],
            ]
            var device = AudioObjectID(kAudioObjectUnknown)
            try Self.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "open system audio")
            deviceID = device
        } catch {
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
    }

    deinit { stop() }

    func start(store: AudioBufferStore) throws {
        let format = self.format
        var proc: AudioDeviceIOProcID?
        try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, deviceID, queue) { _, input, _, _, _ in
            // The store converts before returning, so the borrowed buffer never outlives this call.
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil),
                  buffer.frameLength > 0 else { return }
            store.append(buffer)
        }, "read system audio")
        procID = proc
        try Self.check(AudioDeviceStart(deviceID, proc), "start system audio")
    }

    func stop() {
        guard !disposed else { return }
        disposed = true
        if let procID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        procID = nil
        if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
    }

    /// Core Audio's handle for this app, if it has played or recorded audio yet.
    private static func ownProcessObject() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var pid = ProcessInfo.processInfo.processIdentifier
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw RecordingError.message("Could not \(action) (error \(status)).") }
    }
}
