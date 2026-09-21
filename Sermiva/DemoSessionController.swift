import Foundation

/// Drives the section-5 session state machine for offline demo playback of
/// the `cafe_vi_en` fixture. No network, no Soniox, and - per the project
/// owner's decision - no real microphone I/O either: demo never asks for
/// OS permission and never opens real capture, so it cannot look like a
/// live session. Playback never depends on capture succeeding, which is
/// what makes that possible without the state machine lying about it -
/// see docs/demo-mic-status.md.
@MainActor
final class DemoSessionController: ObservableObject {
    @Published private(set) var state: SessionState = .idle
    /// Whether the mic is genuinely capturing right now. Deliberately a
    /// separate published value, not derived from `state`: HANDOFF.md
    /// section 5's mic-dock line and the "Dang nghe..." empty state must
    /// reflect real capture, not session progress - see
    /// docs/demo-mic-status.md.
    @Published private(set) var isMicCapturing = false
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
        micPermission: MicPermissionProviding = AutoGrantedMicPermission(),
        audioCapture: AudioCapturing = NullAudioCapture(),
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

    /// The six HANDOFF.md section 5 mic-dock strings. In demo, per the
    /// project owner's decision, there is nothing capturing under any
    /// session state - not even "asking" or "paused", which still imply a
    /// mic that was at some point open - so `isDemo` short-circuits to
    /// "Mic tat" unconditionally, checked before anything else. The
    /// state-driven six-string mapping stays underneath for the real
    /// session Outcome 2 introduces; nothing here builds a live path early,
    /// it only keeps the existing contract reachable once `isDemo` is
    /// false. "Dang nghe" only when `isMicCapturing`, never as a function
    /// of `state` alone, so the claim that live text follows capture, not
    /// session progress, is directly testable. See docs/demo-mic-status.md
    /// for why a live `listening` with no capture falls back to "Mic tat"
    /// rather than a dedicated error string.
    static func micDockText(isMicCapturing: Bool, state: SessionState, isDemo: Bool) -> String {
        if isDemo {
            return "Mic tắt"
        }
        if isMicCapturing {
            return "Đang nghe"
        }
        switch state {
        case .paused: return "Đã tạm dừng"
        case .requestingMic, .connecting: return "Đang mở mic…"
        case .reconnecting: return "Mic giữ, chờ mạng"
        case .micDenied: return "Chưa có quyền mic"
        case .idle, .ended, .authError, .listening: return "Mic tắt"
        }
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
        isMicCapturing = false
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

    /// Attempts capture, then always starts playback regardless of whether
    /// it opened. Microphone and session are separate states (AGENTS.md): a
    /// capture failure is not a permission denial and must not silently
    /// stop the demo from playing. In production this branch is taken on
    /// purpose every time (`NullAudioCapture.start()` always throws), which
    /// is what keeps `isMicCapturing` honestly false throughout a demo
    /// session; see docs/demo-mic-status.md.
    private func startCaptureAndPlayback() {
        do {
            try audioCapture.start()
            isMicCapturing = true
        } catch {
            isMicCapturing = false
        }
        state = .listening
        playbackToken = UUID()
        playNextEvent(token: playbackToken)
    }

    private func pause() {
        playbackToken = UUID()
        audioCapture.stop()
        isMicCapturing = false
        state = .paused
    }

    /// Capture stopped itself for a reason outside the user's own pause tap
    /// (backgrounding, a phone call, media services reset - see
    /// `AudioCapturing`). `isMicCapturing` drops immediately either way. The
    /// session also moves to `paused`, not left "listening" against a dead
    /// mic, so playback does not keep silently advancing while the app is
    /// not even in the foreground - a reasonable choice within section 5's
    /// vocabulary, not the only one; written down here since it is a
    /// judgment call.
    private func handleCaptureStoppedExternally() {
        isMicCapturing = false
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
