import Foundation

@MainActor
protocol OverlayController: AnyObject {
    func show(_ state: OverlayState)
    func hide()
}

enum OverlayState: Equatable {
    case listening(level: Float, seconds: Int)
    case processing
    case complete(String)
    case error(String)
}

/// Phase 1 capture coordinator. Later providers attach after a completed clip.
@MainActor
final class RecordingSession {
    private let recorder: any AudioRecorder
    private let overlay: any OverlayController
    private let now: () -> TimeInterval
    private var startedAt: TimeInterval?
    private var deadline: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var dismiss: Task<Void, Never>?
    private var armed = true
    private(set) var isRecording = false
    var onClip: (@MainActor (RecordedAudio) -> Void)?
    var onSound: (@MainActor (Bool) -> Void)?
    var onStateChange: (@MainActor () -> Void)?

    init(recorder: any AudioRecorder, overlay: any OverlayController,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.recorder = recorder
        self.overlay = overlay
        self.now = now
    }

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .down:
            guard armed, !isRecording else { return }
            armed = false
            begin()
        case .up:
            armed = true
            finish()
        case .cancel:
            cancel()
        }
    }

    private func begin() {
        dismiss?.cancel()
        do {
            try recorder.start()
            startedAt = now()
            isRecording = true
            overlay.show(.listening(level: 0, seconds: 0))
            onStateChange?()
            onSound?(true)
            deadline = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(300)) } catch { return }
                self?.finish()
            }
            meter = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) } catch { return }
                    self?.refreshMeter()
                }
            }
        } catch {
            showError(error.localizedDescription)
        }
    }

    func refreshMeter() {
        guard isRecording, let startedAt else { return }
        if let failure = recorder.failure {
            cancel()
            showError(failure)
            return
        }
        overlay.show(.listening(level: recorder.level, seconds: Int(now() - startedAt)))
    }

    /// Also used for the five-minute deadline; a fresh key release is required to rearm.
    func finish() {
        guard isRecording, let startedAt else { return }
        stopTimers()
        isRecording = false
        self.startedAt = nil
        onStateChange?()
        guard now() - startedAt >= 0.25 else {
            recorder.cancel()
            overlay.hide()
            return
        }
        do {
            let audio = try recorder.stop()
            onSound?(false)
            overlay.show(.processing)
            onClip?(audio)
        } catch {
            recorder.cancel()
            showError(error.localizedDescription)
        }
    }

    func cancel() {
        stopTimers()
        dismiss?.cancel()
        recorder.cancel()
        isRecording = false
        startedAt = nil
        armed = true
        overlay.hide()
        onStateChange?()
    }

    func showProcessing() {
        guard !isRecording else { return }
        dismiss?.cancel()
        overlay.show(.processing)
    }

    func completed(_ message: String) {
        guard !isRecording else { return }
        overlay.show(.complete(message))
        scheduleDismiss()
    }

    func showError(_ message: String) {
        guard !isRecording else { return }
        overlay.show(.error(message))
        scheduleDismiss()
    }

    private func scheduleDismiss() {
        dismiss?.cancel()
        dismiss = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            self?.overlay.hide()
        }
    }

    private func stopTimers() {
        deadline?.cancel(); deadline = nil
        meter?.cancel(); meter = nil
    }
}
