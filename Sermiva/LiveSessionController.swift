import Foundation

/// The three independent settings from HANDOFF.md section 4. Settings (the
/// screen where the owner would change these) is out of scope for this
/// outcome, so a live session always uses the fixed vi/auto/en default
/// demo already ships with `demo-data.json`'s `defaultLanguageConfig` -
/// approved by the project owner as fixed until Settings exists.
struct LiveLanguageConfig {
    let me: String
    let target: String
    /// `nil` means "auto" - a recognition hint only, per HANDOFF section 4.
    let guestHint: String?

    static let `default` = LiveLanguageConfig(me: "vi", target: "en", guestHint: nil)
}

/// Drives the section-5 session state machine for a real Soniox session:
/// real microphone permission and capture through the existing
/// `MicPermissionProviding`/`AudioCapturing` seams, and the two-stream join
/// from docs/soniox-routing.md through `SonioxLiveSessionProtocol`. Mirrors
/// `DemoSessionController`'s state-machine shape exactly (both implement
/// `SessionControlling`, and share `SessionPresentation`'s pure dock rules)
/// but never touches playback scheduling or fixture events - there is
/// nothing simulated here.
@MainActor
final class LiveSessionController: ObservableObject, SessionControlling {
    @Published private(set) var state: SessionState = .idle
    @Published private(set) var isMicCapturing = false
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var elapsed: TimeInterval = 0

    let isDemo = false

    private let apiKey: String
    private let languageConfig: LiveLanguageConfig
    private let micPermission: MicPermissionProviding
    private let audioCapture: AudioCapturing
    private let liveSession: SonioxLiveSessionProtocol
    private var elapsedTimer: Timer?

    init(
        apiKey: String,
        languageConfig: LiveLanguageConfig = .default,
        micPermission: MicPermissionProviding = RealMicPermissionProvider(),
        audioCapture: AudioCapturing = RealAudioCapture(),
        liveSession: SonioxLiveSessionProtocol = SonioxLiveSession()
    ) {
        self.apiKey = apiKey
        self.languageConfig = languageConfig
        self.micPermission = micPermission
        self.audioCapture = audioCapture
        self.liveSession = liveSession

        self.audioCapture.onUnexpectedStop = { [weak self] in
            self?.handleCaptureStoppedExternally()
        }
        self.audioCapture.onAudioBuffer = { [weak self] data in
            self?.liveSession.ingestAudio(data)
        }
        self.liveSession.onSegmentsChanged = { [weak self] segments in
            self?.segments = segments
        }
        self.liveSession.onAuthError = { [weak self] in
            self?.handleAuthError()
        }
        self.liveSession.onDisconnected = { [weak self] in
            self?.handleDisconnected()
        }
        self.liveSession.onReconnected = { [weak self] in
            self?.handleReconnected()
        }
    }

    deinit {
        audioCapture.stop()
    }

    // MARK: - SessionControlling presentation

    var headerText: String {
        SessionPresentation.languageHeaderText(config: languageConfig)
    }

    var micDockText: String {
        SessionPresentation.micDockText(isMicCapturing: isMicCapturing, state: state, isDemo: isDemo)
    }

    var micDotColorRole: SessionPresentation.MicDotColorRole {
        SessionPresentation.micDotColorRole(isMicCapturing: isMicCapturing, state: state, isDemo: isDemo)
    }

    var micIconName: String {
        SessionPresentation.micIconName(isMicCapturing: isMicCapturing, isDemo: isDemo)
    }

    var endSessionBodyText: String {
        EndSessionSheet.bodyText(isDemo: isDemo)
    }

    var isActivityRunning: Bool {
        SessionPresentation.isActivityRunning(for: state)
    }

    var displaySegments: [SegmentDisplay] {
        let running = isActivityRunning
        return segments.map { SegmentDisplay.make(for: $0, isActivityRunning: running) }
    }

    var canEnd: Bool {
        SessionPresentation.canEnd(for: state)
    }

    // MARK: - State machine

    private enum PrimaryAction {
        case beginRequestingMic, resume, pause, startNewSession, none
    }

    private static func primaryAction(for state: SessionState) -> PrimaryAction {
        switch state {
        case .idle, .micDenied: return .beginRequestingMic
        case .paused: return .resume
        case .listening, .reconnecting: return .pause
        case .ended: return .startNewSession
        case .requestingMic, .connecting, .authError: return .none
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
        stopElapsedTimer()
        audioCapture.stop()
        isMicCapturing = false
        state = .ended
        liveSession.end { }
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

    /// Capture is attempted BEFORE the (metered) Soniox sockets are opened,
    /// per the owner's ruling: a startup capture failure must not leave two
    /// billed sockets open with no audio ever reaching them. A capture
    /// failure returns to `.idle` - which already renders "Mic tắt" via
    /// `SessionPresentation.micDockText` (idle + not capturing), the exact
    /// existing string HANDOFF's outcome asks for, with no new state and no
    /// new copy - rather than `.listening`, which would claim a session
    /// that in fact never started.
    private func beginConnecting() {
        state = .connecting
        do {
            try audioCapture.start()
            isMicCapturing = true
        } catch {
            isMicCapturing = false
            state = .idle
            return
        }

        let config = SonioxSessionConfig(
            apiKey: apiKey,
            meLanguage: languageConfig.me,
            targetLanguage: languageConfig.target,
            guestHint: languageConfig.guestHint
        )
        liveSession.start(config: config) { [weak self] ok in
            guard let self, self.state == .connecting else { return }
            if ok {
                self.state = .listening
                self.startElapsedTimer()
            } else {
                // `onAuthError` (wired in init) already handles a genuine
                // 401/402/403 on its own, independent of this completion.
                // A `false` here is a plain connect/network failure with no
                // matching state in HANDOFF section 5's vocabulary - the
                // honest, no-new-copy choice is to stop (closing the
                // sockets that never really started) and return to `.idle`
                // so the existing "Bắt đầu" flow can simply retry - left
                // for the project owner to decide whether this deserves a
                // real state of its own.
                self.audioCapture.stop()
                self.isMicCapturing = false
                self.state = .idle
                // A connect failure can still leave the other socket open
                // (or reconnecting) in the background; end the session
                // outright so nothing keeps billing behind an idle screen.
                self.liveSession.end { }
            }
        }
    }

    /// Capture is attempted before anything else changes, the same
    /// ordering `beginConnecting` uses for the startup case: a resume
    /// capture failure must end in a true state, not one that claims
    /// listening while silently having left the keepalive stopped on
    /// sockets that are still open. On failure, nothing here changes - the
    /// session simply stays `.paused`, keepalive keeps running exactly as
    /// `pause()` left it, and the elapsed timer stays frozen - so the user
    /// can just try Tiếp tục again.
    private func resume() {
        do {
            try audioCapture.start()
        } catch {
            isMicCapturing = false
            return
        }
        isMicCapturing = true
        liveSession.endPauseKeepalive()
        state = .listening
        startElapsedTimer()
    }

    private func pause() {
        audioCapture.stop()
        isMicCapturing = false
        stopElapsedTimer()
        liveSession.beginPauseKeepalive()
        state = .paused
    }

    private func handleCaptureStoppedExternally() {
        isMicCapturing = false
        guard state == .listening else { return }
        stopElapsedTimer()
        liveSession.beginPauseKeepalive()
        state = .paused
    }

    private func handleAuthError() {
        stopElapsedTimer()
        audioCapture.stop()
        isMicCapturing = false
        state = .authError
        // A rejected key is not going to start working mid-stream, and a
        // graceful finalize sequence has nothing left to accomplish after
        // a 401/402/403 - close both sockets immediately rather than wait
        // 1.5 s (or leave them open at all if the user taps "Nhập lại
        // khóa" before that wait finishes).
        liveSession.endImmediately { }
    }

    private func handleDisconnected() {
        guard state == .listening else { return }
        state = .reconnecting
    }

    private func handleReconnected() {
        guard state == .reconnecting else { return }
        state = .listening
    }

    /// "Phiên mới": clears the transcript and restarts immediately, the
    /// same contract `DemoSessionController` implements - a fresh
    /// `SonioxLiveSession` (via `beginConnecting`'s `liveSession.start`)
    /// gets a fresh `SonioxJoinEngine`, so no stale join state survives.
    private func startNewSession() {
        segments = []
        elapsed = 0
        beginRequestingMic()
    }

    private func startElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.elapsed += 1
            }
        }
    }

    private func stopElapsedTimer() {
        elapsedTimer?.invalidate()
        elapsedTimer = nil
    }
}
