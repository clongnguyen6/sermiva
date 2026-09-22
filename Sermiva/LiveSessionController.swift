import Foundation

/// The three independent settings from HANDOFF.md section 4. Settings (the
/// screen where the owner would change these) is out of scope for this
/// outcome, so a live session always uses the same defaults demo already
/// ships with `demo-data.json`'s `defaultLanguageConfig` - see the
/// hand-off report's open questions for what that means once Settings
/// exists.
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

    private func beginConnecting() {
        state = .connecting
        let config = SonioxSessionConfig(
            apiKey: apiKey,
            meLanguage: languageConfig.me,
            targetLanguage: languageConfig.target,
            guestHint: languageConfig.guestHint
        )
        liveSession.start(config: config) { [weak self] ok in
            guard let self, self.state == .connecting else { return }
            if ok {
                self.startCaptureAndListening()
            } else {
                // No distinct "could not connect" state exists in HANDOFF's
                // section 5 - authError is the closest existing terminal
                // state that stops the stream and points at fixing the key,
                // even though a plain network failure is not really an
                // auth problem. Flagged in the hand-off report.
                self.state = .authError
            }
        }
    }

    private func startCaptureAndListening() {
        do {
            try audioCapture.start()
            isMicCapturing = true
        } catch {
            isMicCapturing = false
        }
        state = .listening
        startElapsedTimer()
    }

    private func resume() {
        liveSession.endPauseKeepalive()
        do {
            try audioCapture.start()
            isMicCapturing = true
        } catch {
            isMicCapturing = false
        }
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
