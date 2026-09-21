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
        self.audioCapture.onUnexpectedStop = { [weak self] in
            self?.handleCaptureStoppedExternally()
        }
    }

    deinit {
        // The mic must not stay open once this controller leaves the view tree.
        audioCapture.stop()
    }

    /// Whether "Ket thuc" may open the confirmation sheet right now. A pure
    /// function of state so it is directly testable for states (like
    /// `reconnecting`) that this offline slice never actually reaches -
    /// see `SessionStateMachineTests`.
    static func canEnd(for state: SessionState) -> Bool {
        switch state {
        case .requestingMic, .connecting, .listening, .paused, .reconnecting:
            return true
        case .idle, .micDenied, .authError, .ended:
            return false
        }
    }

    var canEnd: Bool { Self.canEnd(for: state) }

    private enum PrimaryAction {
        case beginRequestingMic
        case resume
        case pause
        case startNewSession
        case none
    }

    /// Maps the primary dock button per HANDOFF.md section 5: idle ->
    /// Bat dau, listening/reconnecting -> Tam dung, paused -> Tiep tuc,
    /// connecting -> spinner (disabled), ended -> Phien moi. `micDenied`
    /// re-checks the real permission (the OS answers instantly once it has
    /// already been decided, so this is how a grant via Settings takes
    /// effect - see docs/demo-mic-status.md). `requestingMic` and
    /// `authError` stay inert: the section-5 table defines no action for
    /// them here.
    private static func primaryAction(for state: SessionState) -> PrimaryAction {
        switch state {
        case .idle, .micDenied:
            return .beginRequestingMic
        case .paused:
            return .resume
        case .listening, .reconnecting:
            return .pause
        case .ended:
            return .startNewSession
        case .requestingMic, .connecting, .authError:
            return .none
        }
    }

    func primaryButtonTapped() {
        switch Self.primaryAction(for: state) {
        case .beginRequestingMic: beginRequestingMic()
        case .resume: resume()
        case .pause: pause()
        case .startNewSession: startNewSession()
        case .none: break
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
        startCaptureAndPlayback()
    }

    private func resume() {
        startCaptureAndPlayback()
    }

    /// Starts real capture and, on success, playback. A capture failure
    /// here is an engine/hardware problem, not a permission denial - HANDOFF
    /// section 5 has no dedicated mic-error state and the design has no
    /// banner for it, so this returns to `idle` ("Mic tat") rather than
    /// inventing one. Flagged as a gap for the project owner in the handoff
    /// report.
    private func startCaptureAndPlayback() {
        do {
            try audioCapture.start()
            state = .listening
            playbackToken = UUID()
            playNextEvent(token: playbackToken)
        } catch {
            state = .idle
        }
    }

    private func pause() {
        playbackToken = UUID()
        audioCapture.stop()
        state = .paused
    }

    /// Capture stopped itself for a reason outside the user's own pause tap
    /// (backgrounding, a phone call, media services reset - see
    /// `AudioCapturing`). The dock must never keep saying "Dang nghe" once
    /// that has happened, so this mirrors `pause()` without calling
    /// `audioCapture.stop()` again (it already stopped).
    private func handleCaptureStoppedExternally() {
        guard state == .listening else { return }
        playbackToken = UUID()
        state = .paused
    }

    /// "Phien moi" clears the transcript and restarts the flow immediately,
    /// per the approved prototype's `replay()` + `startFlow()` - it does not
    /// stop at idle waiting for a second tap.
    private func startNewSession() {
        playbackToken = UUID()
        segments = []
        elapsed = 0
        eventIndex = 0
        beginRequestingMic()
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
