import AVFAudio
import Foundation

/// The production audio backend for a live session: `AVAudioEngine` tap ->
/// `AVAudioConverter` -> Int16 16 kHz mono, per docs/soniox-routing.md's
/// session-lifecycle section. Delivers identical bytes to whatever
/// `onAudioBuffer` is wired to; it has no idea there are two sockets on the
/// other end - that buffering-until-both-ready decision belongs to
/// `SonioxLiveSession`, not here, so this stays the thin capture seam
/// `AudioCapturing` already defines.
final class RealAudioCapture: AudioCapturing {
    enum CaptureError: Error {
        case converterUnavailable
        case engineStartFailed(Error)
    }

    var onUnexpectedStop: (@MainActor () -> Void)?
    var onAudioBuffer: (@MainActor (Data) -> Void)?

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true)!
    private var isRunning = false

    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)

        let input = engine.inputNode
        let inputFormat = input.inputFormat(forBus: 0)
        guard inputFormat.channelCount > 0, inputFormat.sampleRate > 0 else {
            throw CaptureError.converterUnavailable
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw CaptureError.converterUnavailable
        }
        self.converter = converter

        NotificationCenter.default.addObserver(
            self, selector: #selector(handleInterruption),
            name: AVAudioSession.interruptionNotification, object: session
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(handleMediaServicesReset),
            name: AVAudioSession.mediaServicesWereResetNotification, object: session
        )

        input.installTap(onBus: 0, bufferSize: 4_096, format: inputFormat) { [weak self] buffer, _ in
            self?.convertAndDeliver(buffer)
        }

        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw CaptureError.engineStartFailed(error)
        }
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        NotificationCenter.default.removeObserver(self)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func convertAndDeliver(_ buffer: AVAudioPCMBuffer) {
        guard let converter, let callback = onAudioBuffer else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var consumed = false
        let status = converter.convert(to: outBuffer, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData, error == nil, let channelData = outBuffer.int16ChannelData else { return }

        let frameCount = Int(outBuffer.frameLength)
        let data = Data(bytes: channelData[0], count: frameCount * MemoryLayout<Int16>.size)
        Task { @MainActor in
            callback(data)
        }
    }

    @objc private func handleInterruption(_ notification: Notification) {
        guard
            let info = notification.userInfo,
            let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
            let type = AVAudioSession.InterruptionType(rawValue: typeValue),
            type == .began
        else { return }
        reportUnexpectedStop()
    }

    @objc private func handleMediaServicesReset() {
        reportUnexpectedStop()
    }

    private func reportUnexpectedStop() {
        stop()
        Task { @MainActor in
            onUnexpectedStop?()
        }
    }
}
