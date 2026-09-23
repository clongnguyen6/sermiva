import Foundation
import Translation

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
/// `MicPermissionProviding`/`AudioCapturing` seams, the single Soniox socket
/// through `SonioxLiveSessionProtocol`, and the on-device `me -> target`
/// translation gate/banner from docs/soniox-routing.md. Mirrors
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

    /// Created once, ever, on this controller's first session start, then
    /// never reassigned/invalidated/nilled again (fatalError rule 2) - see
    /// `prepareTranslationForSessionStart`. `nil` until that first async
    /// resolution completes, which is what keeps
    /// `ConversationView`'s `.translationTask` closure from running before
    /// then.
    @Published private(set) var translationConfiguration: TranslationSession.Configuration?
    /// Re-checked at every live session start (fresh each "Phiên mới"),
    /// since the device's installed language packs can change between
    /// sessions - never in demo.
    @Published private(set) var showsTranslationUnavailableBanner = false

    private let apiKey: String
    private let languageConfig: LiveLanguageConfig
    private let micPermission: MicPermissionProviding
    private let audioCapture: AudioCapturing
    private let liveSession: SonioxLiveSessionProtocol
    /// The seam behind the live session-start availability check - real
    /// Apple Translation calls by default, a fake in `LiveSessionControllerTests`.
    private let translationAvailability: MeToTargetAvailabilityChecking
    private var elapsedTimer: Timer?
    /// Bumped at the start of every new attempt (`beginRequestingMic`) and
    /// again when its own check actually begins (`prepareTranslationForSessionStart`),
    /// so a belated availability result from an attempt that is no longer
    /// the current one is recognised as stale and ignored, even during a
    /// later attempt's own `.requestingMic`/`.connecting` window, where
    /// `canEnd(for: state)` alone would still pass (review round 3,
    /// finding 2).
    private var translationCheckEpoch = 0

    init(
        apiKey: String,
        languageConfig: LiveLanguageConfig = .default,
        micPermission: MicPermissionProviding = RealMicPermissionProvider(),
        audioCapture: AudioCapturing = RealAudioCapture(),
        liveSession: SonioxLiveSessionProtocol = SonioxLiveSession(),
        translationAvailability: MeToTargetAvailabilityChecking = RealMeToTargetAvailabilityChecker()
    ) {
        self.apiKey = apiKey
        self.languageConfig = languageConfig
        self.micPermission = micPermission
        self.audioCapture = audioCapture
        self.liveSession = liveSession
        self.translationAvailability = translationAvailability

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

    // MARK: - On-device me -> target translation (pass-through to `liveSession`)

    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)> {
        liveSession.makeTranslationRequests()
    }

    func reportTranslationStarted(id: Int) -> Bool {
        liveSession.reportTranslationStarted(id: id)
    }

    func reportTranslationSuccess(id: Int, target: String) {
        liveSession.reportTranslationSuccess(id: id, target: target)
    }

    func reportTranslationFailure(id: Int) {
        liveSession.reportTranslationFailure(id: id)
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
        showsTranslationUnavailableBanner = false
        liveSession.end { }
    }

    private func beginRequestingMic() {
        // Review round 3, finding 2: bumped here, at the start of every new
        // attempt (fresh or "Phiên mới") - not only once `prepareTranslation
        // ForSessionStart` itself runs. A previous attempt's own check can
        // still be in flight when this one begins; without invalidating it
        // right away, it could resolve during THIS attempt's own
        // `.requestingMic`/`.connecting` window - both `canEnd`-true, so
        // that guard alone would not have caught it - and, if this attempt's
        // capture then fails before ever reaching `prepareTranslationForSessionStart`
        // itself, the stale result's banner would be left showing on the
        // idle screen behind it. Bumping immediately here closes that
        // window entirely, before mic permission is even requested.
        translationCheckEpoch += 1
        showsTranslationUnavailableBanner = false
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

    /// Capture is attempted BEFORE the (metered) Soniox socket is opened,
    /// per the owner's ruling: a startup capture failure must not leave a
    /// billed socket open with no audio ever reaching it. A capture
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

        prepareTranslationForSessionStart()

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
                // socket that never really started) and return to `.idle`
                // so the existing "Bắt đầu" flow can simply retry - left
                // for the project owner to decide whether this deserves a
                // real state of its own.
                self.audioCapture.stop()
                self.isMicCapturing = false
                self.state = .idle
                // Review round 2: the availability check can resolve (and
                // set the banner) before the connect failure above ever
                // happens - clear it explicitly rather than leave it
                // claiming unavailability against a session that no longer
                // exists.
                self.showsTranslationUnavailableBanner = false
                // A connect failure can still leave the socket open (or
                // reconnecting) in the background; end the session outright
                // so nothing keeps billing behind an idle screen.
                self.liveSession.end { }
            }
        }
    }

    /// Capture is attempted before anything else changes, the same
    /// ordering `beginConnecting` uses for the startup case: a resume
    /// capture failure must end in a true state, not one that claims
    /// listening while silently having left the keepalive stopped on a
    /// socket that is still open. On failure, nothing here changes - the
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
        showsTranslationUnavailableBanner = false
        // A rejected key is not going to start working mid-stream, and a
        // graceful finalize sequence has nothing left to accomplish after
        // a 401/402/403 - close the socket immediately rather than wait
        // 1.5 s (or leave it open at all if the user taps "Nhập lại khóa"
        // before that wait finishes).
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
    /// same contract `DemoSessionController` implements - `beginConnecting`'s
    /// `liveSession.start` gets a fresh `SonioxJoinEngine`, and
    /// `prepareTranslationForSessionStart` re-runs its own availability
    /// check, so no stale per-session state survives either way.
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

    // MARK: - On-device me -> target translation setup

    /// Runs at every live session start (fatalError rule: "At every live
    /// session start, the controller calls `LanguageAvailability().status(
    /// from:to:)`"). Review round 2, finding 1: this is the ONLY place
    /// `liveSession.setTranslationAvailable` is ever set `true` - it starts
    /// `false` at every session start (`SonioxLiveSession.start`) and only
    /// this method flips it, and only once `.installed` is confirmed for
    /// THIS attempt. `translationConfiguration` is created at most once,
    /// ever, per controller (fatalError rule 2), and - review round 2,
    /// finding 1's explicit decision - only once `.installed` is actually
    /// confirmed: creating it for `.supported` would let the very first
    /// `translate` call trigger the system's own download sheet mid-session
    /// while the mic is live, which is never acceptable.
    private func prepareTranslationForSessionStart() {
        showsTranslationUnavailableBanner = false
        // Fail closed the instant a new attempt starts - never enqueue on a
        // guess while this attempt's own check is still in flight.
        liveSession.setTranslationAvailable(false)
        translationCheckEpoch += 1
        let epoch = translationCheckEpoch
        // me != target is enforced before the configuration is created
        // (fatalError rule 8) - always true for the fixed vi/en default,
        // checked here as a real guard rather than assumed.
        guard languageConfig.me != languageConfig.target else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let (source, target) = await self.translationAvailability.resolveLanguages()
            let status = await self.translationAvailability.status(from: source, to: target)
            // Only while this is still the CURRENT attempt (a later
            // "Phiên mới" has not already started its own check) and it is
            // still genuinely running - not aborted or ended (`.idle`,
            // `.micDenied`, `.authError`, `.ended`) - matching
            // `SessionPresentation.canEnd`'s own notion of "still running".
            guard self.translationCheckEpoch == epoch, SessionPresentation.canEnd(for: self.state) else { return }
            let installed = status == .installed
            if installed {
                if self.translationConfiguration == nil {
                    self.translationConfiguration = TranslationSession.Configuration(source: source, target: target)
                }
                self.liveSession.setTranslationAvailable(true)
            }
            self.showsTranslationUnavailableBanner = !installed
        }
    }
}
