import AVFAudio

/// Wraps genuine microphone capture so the session state machine can be
/// driven by a fake in tests instead of real audio hardware.
protocol AudioCapturing: AnyObject {
    func start() throws
    func stop()
}

/// Opens a real `AVAudioEngine` tap while the dock says "Dang nghe", so that
/// label is never shown without capture actually running - see
/// docs/demo-mic-status.md for why this slice opens the mic at all when it
/// has nothing to transcribe.
///
/// The tapped buffers are discarded immediately: no audio is stored, sent
/// anywhere, or run through recognition. That is Soniox's job and is out of
/// scope for this slice.
final class MicrophoneCapture: AudioCapturing {
    private let engine = AVAudioEngine()
    private var isRunning = false

    func start() throws {
        guard !isRunning else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .voiceChat, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { _, _ in }
        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isRunning = false
    }
}
