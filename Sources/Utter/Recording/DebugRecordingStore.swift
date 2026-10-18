import Foundation

actor DebugRecordingStore {
    private let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory
            .appending(path: "Utter/debug", directoryHint: .isDirectory)
    }
    func save(_ audio: RecordedAudio) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appending(path: "last-recording.wav")
        try audio.wavData().write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
