import AVFAudio
import UIKit

/// Wraps genuine microphone capture so the session state machine can be
/// driven by a fake in tests instead of real audio hardware.
///
/// `onUnexpectedStop` fires when capture stops for a reason outside an
/// explicit `stop()` call - backgrounding, an interruption (a call, Siri,
/// another app taking the mic), or a media services reset. The dock must
/// never keep saying "Dang nghe" once that has happened, so the controller
/// uses this to fall back to a state that is actually true.
protocol AudioCapturing: AnyObject {
    var onUnexpectedStop: (@MainActor () -> Void)? { get set }
    func start() throws
    func stop()
}

/// Opens a real `AVAudioEngine` tap while the dock says "Dang nghe", so that
/// label is never shown without capture actually running - see
/// docs/demo-mic-status.md for why this slice opens the mic at all when it
/// has nothing to transcribe, and for the audio session category chosen.
///
/// The tapped buffers are discarded immediately: no audio is stored, sent
/// anywhere, or run through recognition. That is Soniox's job and is out of
/// scope for this slice.
final class MicrophoneCapture: AudioCapturing {
    private let engine = AVAudioEngine()
    private var isRunning = false
    var onUnexpectedStop: (@MainActor () -> Void)?
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                guard
                    let typeValue = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                    AVAudioSession.InterruptionType(rawValue: typeValue) == .began
                else { return }
                self?.handleExternalStop()
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                self?.handleExternalStop()
            },
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // No `UIBackgroundModes: audio` entitlement is declared, so
                // iOS silently stops the tap on backgrounding regardless;
                // this makes that real, external stop visible right away
                // instead of leaving "Dang nghe" stale until some later
                // observation happens to notice.
                self?.handleExternalStop()
            },
        ]
    }

    deinit {
        let center = NotificationCenter.default
        observers.forEach { center.removeObserver($0) }
    }

    enum CaptureError: Error {
        /// The input node has no usable channels - `installTapOnBus` throws
        /// an Objective-C exception (not a catchable Swift error) for a
        /// zero-channel format, which aborts the whole process. This is
        /// checked and turned into a normal `throw` before ever calling it.
        case noInputAvailable
    }

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        let input = engine.inputNode
        do {
            // `.record`, not `.playAndRecord`: this slice never plays audio
            // back, so it must not force the output route to the speaker or
            // to Bluetooth HFP - see docs/demo-mic-status.md.
            try session.setCategory(.record, mode: .default)
            try session.setActive(true)
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0 else {
                throw CaptureError.noInputAvailable
            }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
            engine.prepare()
            try engine.start()
            isRunning = true
        } catch {
            input.removeTap(onBus: 0)
            engine.stop()
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func stop() {
        guard isRunning else { return }
        stopInternal()
    }

    private func handleExternalStop() {
        guard isRunning else { return }
        stopInternal()
        let callback = onUnexpectedStop
        Task { @MainActor in
            callback?()
        }
    }

    private func stopInternal() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }
}
