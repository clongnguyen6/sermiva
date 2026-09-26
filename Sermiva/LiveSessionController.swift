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
    @Published private(set) var state: SessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            lifecycleLogger.log("controller #\(self.controllerId, privacy: .public) state .\(String(describing: self.state), privacy: .public)")
        }
    }
    @Published private(set) var isMicCapturing = false
    @Published private(set) var segments: [Segment] = []
    @Published private(set) var elapsed: TimeInterval = 0

    let isDemo = false

    /// Review round 5, finding A: a unique id for this controller OBJECT,
    /// logged at creation/destruction so the owner's next live session can
    /// tell directly from the Console whether more than one
    /// `LiveSessionController` was ever alive at once - one of the
    /// hypotheses still open in the still-unexplained two-socket evidence.
    let controllerId = LifecycleIds.controller.next()

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
    /// Review round 4, finding 5: set only when the FIRST connect of a
    /// session attempt fails for a non-auth reason (`onAuthError` handles
    /// auth separately, with its own banner) - never for a mid-session
    /// reconnect, which already has "Mất mạng" via `.reconnecting`. Cleared
    /// only once a later attempt actually succeeds.
    @Published private(set) var showsNetworkErrorBanner = false

    private let apiKey: String
    private let languageConfig: LiveLanguageConfig
    private let micPermission: MicPermissionProviding
    private let audioCapture: AudioCapturing
    private let liveSession: SonioxLiveSessionProtocol
    /// The seam behind the live session-start availability check - real
    /// Apple Translation calls by default, a fake in `LiveSessionControllerTests`.
    private let translationAvailability: MeToTargetAvailabilityChecking
    private let scheduler: DemoScheduler
    private var elapsedTimer: Timer?
    /// Review round 4, finding 4b (owner decision): true while `endSession`'s
    /// short grace wait (see `endSession`) is pending. `@Published` (review
    /// round 5, findings 4/7): `canEnd` and `primaryButtonTapped` both react
    /// to it, and neither is itself a `@Published` property that would
    /// otherwise tell SwiftUI to re-render when this flips while `state`
    /// stays unchanged at `.reconnecting` throughout the wait. Also doubles
    /// as the signal the scheduled closure itself checks before finishing
    /// the end - `handleAuthError` clears it early so a rejected key arriving
    /// mid-wait is never overwritten by the pending `.ended` (finding B3).
    @Published private(set) var isEndPending = false
    /// The two independent facts a running session's displayed state is
    /// derived from - see `runningState`. Kept as levels, not inferred from
    /// the last transition: round 5 dropped `onReconnected`/`onDisconnected`
    /// whenever they arrived while paused, so the screen could stay
    /// `.reconnecting` on a live connection, or claim `.listening` with no
    /// connection at all, after resuming (review of 54b3202, findings 1-2).
    private var isPaused = false
    private var isConnected = false
    /// Bumped whenever a pending end grace wait must no longer act.
    private var endGraceToken = 0
    /// Bumped at every Bắt đầu / Phiên mới: a permission answer only ever
    /// applies to the attempt that asked for it, and only while it still
    /// waits for it - never after Kết thúc, never to a later attempt.
    private var permissionAttempt = 0
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
        translationAvailability: MeToTargetAvailabilityChecking = RealMeToTargetAvailabilityChecker(),
        scheduler: DemoScheduler = DispatchScheduler()
    ) {
        self.apiKey = apiKey
        self.languageConfig = languageConfig
        self.micPermission = micPermission
        self.audioCapture = audioCapture
        self.liveSession = liveSession
        self.translationAvailability = translationAvailability
        self.scheduler = scheduler

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
        lifecycleLogger.log("controller #\(self.controllerId, privacy: .public) created")
    }

    deinit {
        audioCapture.stop()
        lifecycleLogger.log("controller #\(self.controllerId, privacy: .public) deinit")
    }

    // MARK: - SessionControlling presentation

    var headerText: String {
        SessionPresentation.languageHeaderText(config: languageConfig)
    }

    var meLanguage: String { languageConfig.me }
    var targetLanguage: String { languageConfig.target }

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

    /// Review round 5, finding 7 (blocking): also `false` while
    /// `isEndPending` - `state` alone stays `.reconnecting` for the whole
    /// grace wait, so without this the "Kết thúc" button stayed tappable
    /// and could reopen `EndSessionSheet` mid-wait, alongside `endSession`'s
    /// own `isEndPending` guard (which stops a second tap from scheduling a
    /// second end, but does nothing to stop the sheet itself popping back
    /// up).
    var canEnd: Bool {
        SessionPresentation.canEnd(for: state) && !isEndPending
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
        // Review round 5, finding B4/4 (blocking): pause and resume must
        // not be possible during the end grace wait, functionally, not
        // merely by disabling the button - defence in depth, since the
        // button being tappable at all during the wait is exactly what
        // finding 4 reported.
        guard !isEndPending else { return }
        switch Self.primaryAction(for: state) {
        case .beginRequestingMic: beginRequestingMic()
        case .resume: resume()
        case .pause: pause()
        case .startNewSession: startNewSession()
        case .none: break
        }
    }

    /// Review round 4, finding 4b (owner decision): the first mock session
    /// lost its last two sentences because ending mid-reconnect closed the
    /// socket immediately, discarding audio still only buffered locally,
    /// waiting for the connection to come back so it could actually be sent
    /// and finalized. Pressing Kết thúc while `.reconnecting` now waits a
    /// short, fixed, bounded time first - a simple timeout, not a "wait
    /// until confirmed flushed" mechanism, since the latter has no bound if
    /// the network never comes back at all.
    ///
    /// Review round 5, lead ruling (finding 5, blocking): the mic stops the
    /// INSTANT this is confirmed - only audio already captured before this
    /// point is ever flushed during the wait, never anything captured
    /// during it. `state` itself stays `.reconnecting` throughout (no new
    /// state), so the dock's mic-off truth comes from `isMicCapturing`
    /// alone - see `SessionPresentation.micDockText`'s own fix for the
    /// "Mic giữ, chờ mạng" line this would otherwise still claim.
    /// `canEnd`/`primaryButtonTapped` both also gate on `isEndPending` now
    /// (findings 4 and 7), so neither Kết thúc nor Tạm dừng/Tiếp tục is
    /// reachable for the wait's duration.
    ///
    /// "Mid-reconnect" means the connection is down, whether or not the
    /// user had paused: a paused session with no connection still has
    /// unsent audio from before the pause waiting for one.
    func endSession() {
        guard canEnd else { return }
        guard isSessionRunning, !isConnected else {
            finishEnding()
            return
        }
        audioCapture.stop()
        isMicCapturing = false
        isEndPending = true
        endGraceToken += 1
        let token = endGraceToken
        scheduler.schedule(after: 3) { [weak self] in
            // Review round 5, finding B3 (blocking): if a rejected key
            // arrived during the wait, `handleAuthError` already ended the
            // session its own way (`endImmediately`, `.authError`) and
            // invalidated this wait - it must then be a complete no-op, or
            // it would overwrite `.authError` with `.ended`, lose the auth
            // banner, and leave the rejected key in Keychain with no
            // "Nhập lại khóa" ever shown for it.
            guard let self, self.endGraceToken == token, self.isEndPending else { return }
            self.finishEnding()
        }
    }

    private func finishEnding() {
        stopElapsedTimer()
        audioCapture.stop()
        isMicCapturing = false
        isEndPending = false
        isPaused = false
        state = .ended
        showsTranslationUnavailableBanner = false
        liveSession.end { }
    }

    /// A session that has connected at least once and has not ended.
    private var isSessionRunning: Bool {
        state == .listening || state == .reconnecting || state == .paused
    }

    /// The one place a running session's displayed state is decided, from
    /// the user's pause and the connection's own reported status: paused
    /// wins, otherwise the screen says exactly whether the connection is up.
    private func runningState() -> SessionState {
        if isPaused { return .paused }
        return isConnected ? .listening : .reconnecting
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
        // Review of 46e9ca0, item 1: whatever the previous session still
        // owns - a connection closing after Kết thúc, on-device translation -
        // is let go of here, at the tap, not only once `liveSession.start`
        // runs: the permission answer can take any time, and a capture
        // failure never reaches `start` at all.
        liveSession.discardPreviousSession()
        showsTranslationUnavailableBanner = false
        isPaused = false
        isConnected = false
        state = .requestingMic
        permissionAttempt += 1
        let attempt = permissionAttempt
        micPermission.requestPermission { [weak self] granted in
            guard let self, self.permissionAttempt == attempt, self.state == .requestingMic else { return }
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
            // Review round 5, finding C9: the network-error banner shows
            // only while it is TRUE - a mic capture failure is a different
            // failure entirely, not a network one, so a stale "Lỗi mạng,
            // thử lại sau" from an earlier attempt must not keep claiming a
            // network problem here.
            showsNetworkErrorBanner = false
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
                self.isConnected = true
                self.state = self.runningState()
                // Review round 4, finding 5: only a LATER attempt actually
                // succeeding clears the network-error banner - never merely
                // being retried.
                self.showsNetworkErrorBanner = false
                // An interruption during the connect already paused it.
                if !self.isPaused {
                    self.startElapsedTimer()
                }
            } else {
                // `onAuthError` (wired in init) already handles a genuine
                // 401/402/403 on its own, independent of this completion.
                // A `false` here is a plain connect/network failure with no
                // matching state in HANDOFF section 5's vocabulary - the
                // honest, no-new-copy choice is to stop (closing the
                // socket that never really started) and return to `.idle`,
                // now with the approved prototype's own network-error
                // string shown, so the existing "Bắt đầu" flow can simply
                // retry.
                self.audioCapture.stop()
                self.isMicCapturing = false
                self.state = .idle
                self.showsNetworkErrorBanner = true
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
    /// The state after resuming is whatever is true NOW (`runningState`),
    /// not whatever pausing interrupted: the connection may have dropped or
    /// come back while paused.
    private func resume() {
        do {
            try audioCapture.start()
        } catch {
            isMicCapturing = false
            return
        }
        isMicCapturing = true
        liveSession.endPauseKeepalive()
        isPaused = false
        state = runningState()
        startElapsedTimer()
    }

    private func pause() {
        audioCapture.stop()
        isMicCapturing = false
        stopElapsedTimer()
        liveSession.beginPauseKeepalive()
        isPaused = true
        state = runningState()
    }

    /// An interruption (a call, Siri), a media-services reset or a lost
    /// input route stopped capture. Whatever the connection is doing, the
    /// session is now paused - the one true state with the mic off that
    /// the user can leave with Tiếp tục. Review of 2046102, item 4: round 5
    /// only did this from `.listening`, so an interruption while
    /// `.connecting` or `.reconnecting` later showed `.listening` ("Đã kết
    /// nối", a "Tạm dừng" button, a recognizing caret) with the mic off.
    /// While `.connecting` the state itself stays `.connecting` - it
    /// becomes `.paused` the moment the connection is established - and the
    /// dock says "Mic tắt", the truth (`SessionPresentation.micDockText`).
    private func handleCaptureStoppedExternally() {
        isMicCapturing = false
        guard state == .connecting || isSessionRunning, !isPaused, !isEndPending else { return }
        stopElapsedTimer()
        liveSession.beginPauseKeepalive()
        isPaused = true
        if state != .connecting {
            state = runningState()
        }
    }

    /// `SonioxLiveSession` reports a rejected key until the session's
    /// connection has fully closed - including the short window after
    /// Kết thúc - so this can also move `.ended` to `.authError`: the key is
    /// rejected either way, and "Nhập lại khóa" is the only way to fix it.
    private func handleAuthError() {
        stopElapsedTimer()
        audioCapture.stop()
        isMicCapturing = false
        isPaused = false
        state = .authError
        showsTranslationUnavailableBanner = false
        // Review round 5, finding B3 (blocking): auth wins over a pending
        // end-grace-wait - invalidating it is what makes that wait's own
        // scheduled closure do nothing once it fires, rather than
        // overwrite `.authError` with `.ended` a few seconds later and lose
        // the auth banner (and the user's only chance to remove the
        // rejected key via "Nhập lại khóa").
        isEndPending = false
        endGraceToken += 1
        // A rejected key is not going to start working mid-stream, and a
        // graceful finalize sequence has nothing left to accomplish after
        // a 401/402/403 - close the socket immediately rather than wait
        // 1.5 s (or leave it open at all if the user taps "Nhập lại khóa"
        // before that wait finishes).
        liveSession.endImmediately { }
    }

    private func handleDisconnected() {
        guard isSessionRunning else { return }
        isConnected = false
        state = runningState()
    }

    private func handleReconnected() {
        guard isSessionRunning else { return }
        isConnected = true
        state = runningState()
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
