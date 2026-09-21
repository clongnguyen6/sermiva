import Foundation

/// Drives the section-5 session state machine for offline demo playback of
/// the `cafe_vi_en` fixture. No network and no Soniox: the only real I/O is
/// the microphone permission prompt and, once granted, a genuinely open
/// (but discarded) capture - see docs/demo-mic-status.md.
@MainActor
final class DemoSessionController: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var elapsed: TimeInterval = 0

    private let micPermission: MicPermissionProviding
    private let audioCapture: AudioCapturing
    private let scheduler: DemoScheduler
    private let events: [DemoEvent]
    private let eventInterval: TimeInterval
    private let translationDelay: TimeInterval

    private var eventIndex = 0
    private var playbackToken = UUID()

    init(
        events: [DemoEvent],
        micPermission: MicPermissionProviding = SystemMicPermissionProvider(),
        audioCapture: AudioCapturing = MicrophoneCapture(),
        scheduler: DemoScheduler = DispatchScheduler(),
        eventInterval: TimeInterval = 0.9,
        translationDelay: TimeInterval = 1.4
    ) {
        self.events = events
        self.micPermission = micPermission
        self.audioCapture = audioCapture
        self.scheduler = scheduler
        self.eventInterval = eventInterval
        self.translationDelay = translationDelay
    }

    /// Whether "Ket thuc" may open the confirmation sheet right now.
    var canEnd: Bool {
        switch state {
        case .requestingMic, .connecting, .listening, .paused:
            return true
        case .idle, .micDenied, .reconnecting, .authError, .ended:
            return false
        }
    }

    /// Maps the primary dock button per HANDOFF.md section 5. `requestingMic`,
    /// `micDenied`, `reconnecting` and `authError` are left disabled: the
    /// section-5 table only defines idle/listening/paused/connecting/ended.
    func primaryButtonTapped() {
        switch state {
        case .idle:
            beginRequestingMic()
        case .paused:
            resume()
        case .listening:
            pause()
        case .ended:
            startNewSession()
        case .requestingMic, .connecting, .micDenied, .reconnecting, .authError:
            break
        }
    }

    func endSession() {
        guard canEnd else { return }
        playbackToken = UUID()
        audioCapture.stop()
        state = .ended
    }

    private func beginRequestingMic() {
        state = .requestingMic
        micPermission.requestPermission { [weak self] granted in
            guard let self else { return }
            if granted {
                self.beginConnecting()
            } else {
                self.state = .micDenied
            }
        }
    }

    private func beginConnecting() {
        state = .connecting
        do {
            try audioCapture.start()
            state = .listening
            playbackToken = UUID()
            playNextEvent(token: playbackToken)
        } catch {
            state = .micDenied
        }
    }

    private func resume() {
        do {
            try audioCapture.start()
            state = .listening
            playbackToken = UUID()
            playNextEvent(token: playbackToken)
        } catch {
            state = .micDenied
        }
    }

    private func pause() {
        playbackToken = UUID()
        audioCapture.stop()
        state = .paused
    }

    private func startNewSession() {
        playbackToken = UUID()
        segments = []
        elapsed = 0
        eventIndex = 0
        state = .idle
    }

    private func playNextEvent(token: UUID) {
        guard state == .listening, token == playbackToken, eventIndex < events.count else { return }
        let event = events[eventIndex]
        eventIndex += 1
        elapsed += eventInterval
        SegmentAssembler.apply(event, elapsed: elapsed, to: &segments)
        if event.type == .final, let target = event.tgt {
            scheduler.schedule(after: translationDelay) { [weak self] in
                self?.applyTarget(id: event.id, target: target)
            }
        }
        scheduler.schedule(after: eventInterval) { [weak self] in
            self?.playNextEvent(token: token)
        }
    }

    private func applyTarget(id: Int, target: String) {
        SegmentAssembler.fillTarget(id: id, target: target, in: &segments)
    }
}
