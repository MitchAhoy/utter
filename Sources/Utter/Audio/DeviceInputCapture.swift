import AVFoundation
import AudioToolbox

/// Records from one specific microphone using an input-only audio unit.
///
/// AVAudioEngine drives input and output through one unit. When AirPods are the
/// system output, macOS keeps resetting that unit back to the AirPods mic, so a
/// chosen microphone such as a USB wireless mic receiver never delivers audio.
/// An input-only unit has no output side for macOS to reset.
final class DeviceInputCapture: @unchecked Sendable {
    let format: AVAudioFormat
    private let unit: AudioUnit
    private let buffer: AVAudioPCMBuffer
    private var store: AudioBufferStore?
    private var running = false
    private var disposed = false
    private static let maxFrames: AVAudioFrameCount = 4096

    init(uid: String) throws {
        guard let device = AudioInputDevices.available().first(where: { $0.id == uid }) else {
            throw RecordingError.message("The selected microphone is unavailable. Choose another microphone in General settings.")
        }
        let (unit, format) = try Self.makeUnit(deviceID: device.deviceID)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.maxFrames) else {
            AudioComponentInstanceDispose(unit)
            throw RecordingError.message("Unable to allocate the microphone buffer.")
        }
        self.unit = unit
        self.format = format
        self.buffer = buffer
    }

    deinit { dispose() }

    func start(store: AudioBufferStore) throws {
        self.store = store
        var callback = AURenderCallbackStruct(inputProc: { refCon, flags, timeStamp, bus, frames, _ in
            Unmanaged<DeviceInputCapture>.fromOpaque(refCon).takeUnretainedValue()
                .render(flags: flags, timeStamp: timeStamp, bus: bus, frames: frames)
        }, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try Self.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                            &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "set the input callback")
        try Self.check(AudioUnitInitialize(unit), "prepare the microphone")
        try Self.check(AudioOutputUnitStart(unit), "start the microphone")
        running = true
    }

    func stop() { dispose() }

    private func dispose() {
        guard !disposed else { return }
        disposed = true
        if running { AudioOutputUnitStop(unit) }
        running = false
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
        store = nil
    }

    /// Runs on the audio thread. The store converts the buffer before returning, so it can be reused.
    private func render(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, timeStamp: UnsafePointer<AudioTimeStamp>,
                        bus: UInt32, frames: UInt32) -> OSStatus {
        guard frames <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        buffer.frameLength = frames
        let list = buffer.mutableAudioBufferList
        list.pointee.mBuffers.mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, list)
        if status == noErr { store?.append(buffer) }
        return status
    }

    private static func makeUnit(deviceID: AudioDeviceID) throws -> (AudioUnit, AVAudioFormat) {
        var description = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                                    componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw RecordingError.message("No usable microphone is connected.")
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance), "open the microphone")
        guard let unit = instance else { throw RecordingError.message("No usable microphone is connected.") }
        do {
            var on: UInt32 = 1, off: UInt32 = 0, device = deviceID, maxFrames = UInt32(Self.maxFrames)
            let size32 = UInt32(MemoryLayout<UInt32>.size)
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, size32), "enable input")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, size32), "disable output")
            try check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                           &device, UInt32(MemoryLayout<AudioDeviceID>.size)), "select the microphone")
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
                                           &maxFrames, size32), "set the buffer size")
            var hardware = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &hardware, &size), "read the microphone format")
            guard hardware.mSampleRate > 0,
                  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: hardware.mSampleRate, channels: 1, interleaved: false) else {
                throw RecordingError.message("No usable microphone is connected.")
            }
            // Mono float at the hardware rate; the audio unit takes the first channel.
            var client = format.streamDescription.pointee
            try check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size), "set the microphone format")
            return (unit, format)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw RecordingError.message("Could not \(action) (error \(status)).") }
    }
}
