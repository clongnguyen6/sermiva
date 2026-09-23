import XCTest
import Translation
@testable import Sermiva

/// Covers the section-5 state machine for a real session, driven through
/// `LiveSessionController` with fakes for microphone permission, audio
/// capture, and the Soniox session itself - no socket is ever opened here,
/// per AGENTS.md and the outcome's hard constraint against connecting to
/// the real service from anything but a real user's own tap.
@MainActor
final class LiveSessionControllerTests: XCTestCase {
    private func makeController(
        micGranted: Bool = true,
        audio: FakeAudioCapture = FakeAudioCapture(),
        session: FakeSonioxLiveSession = FakeSonioxLiveSession(),
        translationAvailability: FakeMeToTargetAvailabilityChecker = FakeMeToTargetAvailabilityChecker(),
        scheduler: ManualScheduler = ManualScheduler()
    ) -> (controller: LiveSessionController, audio: FakeAudioCapture, session: FakeSonioxLiveSession, mic: FakeMicPermissionProvider) {
        let mic = FakeMicPermissionProvider(granted: micGranted)
        let controller = LiveSessionController(
            apiKey: "sx_test_key_not_real",
            micPermission: mic,
            audioCapture: audio,
            liveSession: session,
            translationAvailability: translationAvailability,
            scheduler: scheduler
        )
        return (controller, audio, session, mic)
    }

    /// Lets the async availability-check `Task` spawned by
    /// `prepareTranslationForSessionStart` actually run and settle, since
    /// none of these tests can `await` it directly.
    private func settle(yields: Int = 50) async {
        for _ in 0..<yields {
            await Task.yield()
        }
    }

    func test_idleToListeningOpensCaptureAndStartsTheLiveSession() {
        let (controller, audio, session, _) = makeController()

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(audio.startCount, 1)
        XCTAssertEqual(session.startCount, 1)
        XCTAssertFalse(controller.isDemo)
    }

    func test_deniedPermissionGoesToMicDeniedAndNeverStartsASession() {
        let (controller, _, session, _) = makeController(micGranted: false)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .micDenied)
        XCTAssertEqual(session.startCount, 0, "a denied permission must never open a Soniox session")
    }

    /// Issue 5: a plain connect/network failure (as opposed to a genuine
    /// 401/402/403, which arrives through `onAuthError` instead) has no
    /// matching state in HANDOFF section 5 - the honest, no-new-copy
    /// choice is to fall back to `.idle`, not invent or misuse `.authError`.
    func test_genericSessionStartFailureGoesToIdleNotAuthErrorAndEndsTheSession() {
        let session = FakeSonioxLiveSession()
        session.nextStartResult = false
        let (controller, audio, _, _) = makeController(session: session)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .idle, "a plain connect failure must not be reported as an auth error")
        XCTAssertFalse(controller.isMicCapturing)
        XCTAssertFalse(controller.canEnd)
        XCTAssertEqual(session.endCount, 1, "a connect failure must not leave the socket billing in the background")
        _ = audio
    }

    /// Issue 6: a startup capture failure must not still open two metered
    /// sockets with no audio ever reaching them, and must not claim the
    /// session is listening when it never really started.
    func test_startupCaptureFailurePreventsOpeningTheSonioxSessionEntirely() {
        let audio = FakeAudioCapture()
        audio.failNextStart = true
        let (controller, _, session, _) = makeController(audio: audio)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .idle, "must not claim listening when capture never opened")
        XCTAssertFalse(controller.isMicCapturing)
        XCTAssertEqual(session.startCount, 0, "a startup capture failure must not open the metered Soniox socket at all")
        XCTAssertEqual(controller.micDockText, "Mic tắt", "the existing Mic tat state, no new copy")
    }

    func test_pauseStopsCaptureAndBeginsKeepalive() {
        let (controller, audio, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening

        controller.primaryButtonTapped() // -> paused

        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(session.pauseKeepaliveCount, 1)
        XCTAssertFalse(controller.isMicCapturing)
    }

    func test_resumeReopensCaptureAndEndsKeepalive() {
        let (controller, audio, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        controller.primaryButtonTapped() // -> paused

        controller.primaryButtonTapped() // -> listening again

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(audio.startCount, 2)
        XCTAssertEqual(session.resumeCount, 1, "resume must end the pause keepalive")
    }

    /// A resume capture failure must end in a true state: still paused
    /// (not claiming listening), and the keepalive that `pause()` started
    /// must still be running on the sockets that are still open - not
    /// silently stopped for a resume that never actually happened.
    func test_resumeCaptureFailureStaysPausedAndKeepsKeepaliveRunning() {
        let audio = FakeAudioCapture()
        let (controller, _, session, _) = makeController(audio: audio)
        controller.primaryButtonTapped() // -> listening
        controller.primaryButtonTapped() // -> paused
        XCTAssertEqual(session.pauseKeepaliveCount, 1)

        audio.failNextStart = true
        controller.primaryButtonTapped() // attempt resume, capture fails

        XCTAssertEqual(controller.state, .paused, "a resume capture failure must not claim listening")
        XCTAssertFalse(controller.isMicCapturing)
        XCTAssertEqual(session.resumeCount, 0, "keepalive must not stop for a resume that never truly happened")
    }

    func test_authErrorCallbackStopsCaptureAndMovesState() {
        let (controller, audio, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        XCTAssertTrue(controller.isMicCapturing)

        session.onAuthError?()

        XCTAssertEqual(controller.state, .authError)
        XCTAssertFalse(controller.isMicCapturing)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(session.endImmediatelyCount, 1, "a rejected key must close immediately, not via the graceful finalize sequence")
        XCTAssertEqual(session.endCount, 0, "finalize is pointless after a 401/402/403")
    }

    func test_disconnectedWhileListeningMovesToReconnectingAndReconnectedReturnsToListening() {
        let (controller, _, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening

        session.onDisconnected?()
        XCTAssertEqual(controller.state, .reconnecting)
        XCTAssertTrue(controller.canEnd, "a reconnecting session is still running: Ket thuc must stay reachable")

        session.onReconnected?()
        XCTAssertEqual(controller.state, .listening)
    }

    func test_disconnectedSignalWhileNotListeningIsANoOp() {
        let (controller, _, session, _) = makeController()
        XCTAssertEqual(controller.state, .idle)

        session.onDisconnected?()

        XCTAssertEqual(controller.state, .idle, "a stray disconnect signal before any session started must not move state")
    }

    func test_segmentsChangedCallbackUpdatesTheControllersSegments() {
        let (controller, _, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        let segment = Segment(id: 1, speaker: "A", lang: "vi", source: "Xin chào", target: nil, isFinal: true, startedAt: 0, overlap: false)

        session.onSegmentsChanged?([segment])

        XCTAssertEqual(controller.segments, [segment])
        XCTAssertEqual(controller.displaySegments.count, 1)
    }

    func test_endSessionStopsCaptureAndEndsTheLiveSession() {
        let (controller, audio, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        XCTAssertTrue(controller.canEnd)

        controller.endSession()

        XCTAssertEqual(controller.state, .ended)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(session.endCount, 1)
        XCTAssertFalse(controller.canEnd)
    }

    // MARK: - Review round 4, finding 4b (owner decision): ending mid-
    // reconnect waits a short bounded time for buffered audio to be sent
    // and finalized, rather than discarding it immediately - live evidence:
    // the first mock session lost its last two sentences exactly this way.

    func test_endingWhileReconnectingWaitsBeforeActuallyEndingRatherThanDiscardingBufferedAudioImmediately() {
        let scheduler = ManualScheduler()
        let (controller, audio, session, _) = makeController(scheduler: scheduler)
        controller.primaryButtonTapped() // -> listening
        session.onDisconnected?()
        XCTAssertEqual(controller.state, .reconnecting)

        controller.endSession()

        XCTAssertEqual(controller.state, .reconnecting, "must not end immediately - the screen stays exactly as .reconnecting already renders it")
        XCTAssertEqual(session.endCount, 0, "must not close the socket yet - that is exactly what would discard audio still only buffered, waiting to be sent")
        // Review round 5, lead ruling (finding 5): the mic stops the INSTANT
        // Kết thúc is confirmed - only audio captured before this point is
        // ever flushed during the wait.
        XCTAssertEqual(audio.stopCount, 1, "the mic must stop immediately on confirming Kết thúc, not only once the grace wait elapses")
        XCTAssertFalse(controller.isMicCapturing)

        scheduler.drainAll()

        XCTAssertEqual(controller.state, .ended, "once the grace wait elapses, the session ends completely")
        XCTAssertEqual(session.endCount, 1)
        // `RealAudioCapture.stop()` is documented idempotent - `finishEnding`
        // calling it again once the wait elapses is harmless, just redundant.
        XCTAssertEqual(audio.stopCount, 2)
    }

    func test_endingWhileListeningEndsImmediatelyWithNoWait() {
        let scheduler = ManualScheduler()
        let (controller, _, session, _) = makeController(scheduler: scheduler)
        controller.primaryButtonTapped() // -> listening

        controller.endSession()

        XCTAssertEqual(controller.state, .ended, "only a mid-reconnect end waits - a normal end must not be delayed")
        XCTAssertEqual(session.endCount, 1)
        XCTAssertEqual(scheduler.pending.count, 0)
    }

    func test_secondEndTapDuringTheGraceWaitDoesNotScheduleAnOverlappingEnd() {
        let scheduler = ManualScheduler()
        let (controller, _, session, _) = makeController(scheduler: scheduler)
        controller.primaryButtonTapped() // -> listening
        session.onDisconnected?()

        controller.endSession()
        XCTAssertEqual(scheduler.pending.count, 1)
        controller.endSession() // a second tap while still waiting

        XCTAssertEqual(scheduler.pending.count, 1, "a second Kết thúc tap during the wait must not schedule a second, overlapping end")
        scheduler.drainAll()
        XCTAssertEqual(session.endCount, 1, "only one end must ever actually happen")
    }

    func test_newSessionAfterEndClearsSegmentsAndStartsAFreshLiveSession() {
        let (controller, audio, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        session.onSegmentsChanged?([Segment(id: 1, speaker: nil, lang: "vi", source: "a", target: nil, isFinal: true, startedAt: 0, overlap: false)])
        controller.endSession()

        controller.primaryButtonTapped() // "Phien moi"

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(controller.segments, [], "starting a new session must clear the previous session's transcript")
        XCTAssertEqual(session.startCount, 2, "a new session must open a fresh Soniox session, not reuse the ended one")
        XCTAssertEqual(audio.startCount, 2)
    }

    func test_deinitStopsCaptureIfStillOpen() {
        let audio = FakeAudioCapture()
        var controller: LiveSessionController? = LiveSessionController(
            apiKey: "sx_test_key_not_real",
            micPermission: FakeMicPermissionProvider(granted: true),
            audioCapture: audio,
            liveSession: FakeSonioxLiveSession()
        )
        controller?.primaryButtonTapped()
        XCTAssertEqual(audio.startCount, 1)

        controller = nil

        XCTAssertEqual(audio.stopCount, 1, "dropping the controller must stop capture, not leave the mic open")
    }

    // MARK: - On-device me -> target translation pass-through

    func test_translationMethodsPassThroughToTheLiveSession() {
        let session = FakeSonioxLiveSession()
        let (controller, _, _, _) = makeController(session: session)

        _ = controller.makeTranslationRequests()
        _ = controller.reportTranslationStarted(id: 1)
        controller.reportTranslationSuccess(id: 1, target: "Hello")
        controller.reportTranslationFailure(id: 2)

        XCTAssertEqual(session.makeTranslationRequestsCallCount, 1)
        XCTAssertEqual(session.reportedTranslationStarted, [1])
        XCTAssertEqual(session.reportedTranslationSuccess.map(\.id), [1])
        XCTAssertEqual(session.reportedTranslationSuccess.map(\.target), ["Hello"])
        XCTAssertEqual(session.reportedTranslationFailure, [2])
    }

    func test_audioBufferCallbackForwardsToTheLiveSession() {
        let (controller, audio, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening, wires onAudioBuffer

        audio.onAudioBuffer?(Data([0x01, 0x02]))

        XCTAssertEqual(session.ingestedAudioCount, 1)
        _ = controller
    }

    // MARK: - Review round 2, finding 1: the availability status gate

    func test_installedStatusEnablesTranslationCreatesConfigurationAndShowsNoBanner() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .installed
        let session = FakeSonioxLiveSession()
        let (controller, _, _, _) = makeController(session: session, translationAvailability: availability)

        controller.primaryButtonTapped()
        await settle()

        XCTAssertEqual(session.translationAvailableHistory, [false, true], "must fail closed first, then flip true only once .installed is confirmed")
        XCTAssertNotNil(controller.translationConfiguration)
        XCTAssertFalse(controller.showsTranslationUnavailableBanner)
    }

    func test_supportedStatusNeverEnablesTranslationNeverCreatesConfigurationAndShowsTheBanner() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .supported
        let session = FakeSonioxLiveSession()
        let (controller, _, _, _) = makeController(session: session, translationAvailability: availability)

        controller.primaryButtonTapped()
        await settle()

        XCTAssertEqual(session.translationAvailableHistory, [false], "must never flip true for .supported - only .installed may enqueue/translate")
        XCTAssertNil(controller.translationConfiguration, "must never create the configuration for .supported - the first translate call would trigger the system download sheet mid-session")
        XCTAssertTrue(controller.showsTranslationUnavailableBanner)
    }

    func test_unsupportedStatusNeverEnablesTranslationNeverCreatesConfigurationAndShowsTheBanner() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .unsupported
        let session = FakeSonioxLiveSession()
        let (controller, _, _, _) = makeController(session: session, translationAvailability: availability)

        controller.primaryButtonTapped()
        await settle()

        XCTAssertEqual(session.translationAvailableHistory, [false])
        XCTAssertNil(controller.translationConfiguration)
        XCTAssertTrue(controller.showsTranslationUnavailableBanner)
    }

    /// Fatal-error rule 2: created at most once, ever, per controller - and
    /// review round 2's own decision, never recreated for a later "Phiên
    /// mới", `endSession`, or an auth error, even if a later resolution
    /// would have produced something different.
    func test_configurationIsNeverRecreatedAcrossPhienMoiEndOrAuthError() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .installed
        let session = FakeSonioxLiveSession()
        let (controller, _, _, _) = makeController(session: session, translationAvailability: availability)

        controller.primaryButtonTapped()
        await settle()
        let firstIdentifier = controller.translationConfiguration?.source?.maximalIdentifier
        XCTAssertNotNil(firstIdentifier)

        // If the configuration were ever recreated, this would show up.
        availability.source = Locale.Language(identifier: "fr")

        controller.endSession()
        XCTAssertNotNil(controller.translationConfiguration, "end must never nil the configuration out (fatalError rule 2)")

        controller.primaryButtonTapped() // "Phiên mới"
        await settle()
        XCTAssertEqual(controller.translationConfiguration?.source?.maximalIdentifier, firstIdentifier, "must never be recreated for a later Phien moi, even with a different later resolution")

        session.onAuthError?()
        XCTAssertEqual(controller.translationConfiguration?.source?.maximalIdentifier, firstIdentifier, "an auth error must never touch the configuration either")
    }

    // MARK: - Review round 2, finding 5: the banner must not survive a
    // failed connect, even if the availability check resolved (and set it)
    // before the connect failure itself happened.

    func test_bannerClearsAfterAFailedConnectEvenIfTheCheckAlreadySetItTrue() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .unsupported
        let session = FakeSonioxLiveSession()
        session.completesImmediately = false
        let (controller, _, _, _) = makeController(session: session, translationAvailability: availability)

        controller.primaryButtonTapped() // .connecting; availability check in flight, start() withheld
        await settle()
        XCTAssertTrue(controller.showsTranslationUnavailableBanner, "sanity: the availability check resolved first, while still connecting")

        session.completeStart(ok: false) // the connect attempt now fails

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.showsTranslationUnavailableBanner, "a failed connect must clear the banner - it must never claim unavailability for a session that no longer exists")
    }

    // MARK: - Review round 3, finding 2/3: the epoch guard, the canEnd
    // guard, and the two banner-clear call sites, each covered on its own -
    // the reviewer removed each individually and the suite stayed green.

    /// Isolates the epoch guard: a check from an attempt that has already
    /// been superseded by a NEW attempt (bumped epoch) must never apply,
    /// even while that new attempt is still in its own `.requestingMic`/
    /// `.connecting` window, where `canEnd` alone is true and would not
    /// have caught it.
    func test_epochGuardPreventsAStaleCheckFromASupersededAttemptApplyingDuringTheNextOne() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .unsupported
        availability.holdStatus = true
        let session = FakeSonioxLiveSession()
        let (controller, _, _, _) = makeController(session: session, translationAvailability: availability)

        controller.primaryButtonTapped() // attempt 1: its own check (Task A) blocks at status()
        await settle()
        XCTAssertEqual(availability.statusCallCount, 1, "sanity: attempt 1's own check is the one in flight")

        controller.endSession() // attempt 1 ends; Task A is still pending

        // "Phiên mới": attempt 2 bumps the epoch the moment it begins, then
        // reaches its OWN check (Task B, also held) and sits in `.connecting`
        // - a canEnd()-true state - with its own `start()` withheld.
        session.completesImmediately = false
        controller.primaryButtonTapped()
        await settle()
        XCTAssertEqual(availability.statusCallCount, 2, "sanity: attempt 2 reached its own check too")
        XCTAssertEqual(controller.state, .connecting, "sanity: attempt 2 is sitting in a canEnd()-true state when Task A resolves next")

        // Task A (attempt 1's STALE check) finally resolves - canEnd(.connecting)
        // is true, so only the epoch mismatch can reject it here.
        availability.resumeOldestHeldStatus()
        await settle()

        XCTAssertFalse(controller.showsTranslationUnavailableBanner, "a stale check from an already-superseded attempt must never apply during a later attempt's own canEnd()-true window")
    }

    /// Isolates the `canEnd` guard: the SAME attempt's own check resolving
    /// after that attempt has already ended - with no new attempt ever
    /// having started, so the epoch is unchanged - must still be rejected.
    func test_canEndGuardPreventsACheckFromApplyingAfterItsOwnAttemptHasEnded() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .unsupported
        availability.holdStatus = true
        let (controller, _, _, _) = makeController(translationAvailability: availability)

        controller.primaryButtonTapped() // -> listening; its own check blocks at status()
        await settle()

        controller.endSession() // -> .ended; no new attempt started, epoch unchanged

        availability.resumeOldestHeldStatus()
        await settle()

        XCTAssertEqual(controller.state, .ended)
        XCTAssertFalse(controller.showsTranslationUnavailableBanner, "a check must never apply once its own attempt has already ended, even with the epoch unchanged")
    }

    func test_endSessionClearsAnAlreadyShowingBanner() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .unsupported
        let (controller, _, _, _) = makeController(translationAvailability: availability)

        controller.primaryButtonTapped()
        await settle()
        XCTAssertTrue(controller.showsTranslationUnavailableBanner, "sanity: the banner is genuinely showing")

        controller.endSession()

        XCTAssertFalse(controller.showsTranslationUnavailableBanner, "ending a session must clear a still-showing banner")
    }

    func test_authErrorClearsAnAlreadyShowingBanner() async {
        let availability = FakeMeToTargetAvailabilityChecker()
        availability.nextStatus = .unsupported
        let session = FakeSonioxLiveSession()
        let (controller, _, _, _) = makeController(session: session, translationAvailability: availability)

        controller.primaryButtonTapped()
        await settle()
        XCTAssertTrue(controller.showsTranslationUnavailableBanner, "sanity: the banner is genuinely showing")

        session.onAuthError?()

        XCTAssertFalse(controller.showsTranslationUnavailableBanner, "an auth error must clear a still-showing banner")
    }

    // MARK: - Review round 4, finding 5: the initial connect-failure banner

    func test_failedInitialConnectShowsTheNetworkErrorBanner() {
        let session = FakeSonioxLiveSession()
        session.nextStartResult = false
        let (controller, _, _, _) = makeController(session: session)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.showsNetworkErrorBanner)
    }

    func test_networkErrorBannerClearsOnlyOnceALaterAttemptSucceeds() {
        let session = FakeSonioxLiveSession()
        session.nextStartResult = false
        let (controller, _, _, _) = makeController(session: session)
        controller.primaryButtonTapped()
        XCTAssertTrue(controller.showsNetworkErrorBanner, "sanity: showing after the first failure")

        // Retrying while still failing must not clear it early.
        controller.primaryButtonTapped()
        XCTAssertTrue(controller.showsNetworkErrorBanner, "must not clear merely because a retry was attempted")

        session.nextStartResult = true
        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertFalse(controller.showsNetworkErrorBanner, "must clear once a later attempt actually succeeds")
    }

    func test_authErrorNeverShowsTheNetworkErrorBanner() {
        let (controller, _, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening

        session.onAuthError?()

        XCTAssertEqual(controller.state, .authError)
        XCTAssertFalse(controller.showsNetworkErrorBanner, "an auth error must go to its own banner, never this one")
    }

    /// Review round 5, finding C9 (blocking): the banner shows only while
    /// it is TRUE - a later, DIFFERENT kind of failure (mic capture, not
    /// network) must not leave a stale "Lỗi mạng, thử lại sau" up.
    func test_networkErrorBannerClearsOnASubsequentMicCaptureFailureToo() {
        let session = FakeSonioxLiveSession()
        session.nextStartResult = false
        let audio = FakeAudioCapture()
        let (controller, _, _, _) = makeController(audio: audio, session: session)
        controller.primaryButtonTapped()
        XCTAssertTrue(controller.showsNetworkErrorBanner, "sanity: showing after the first, network-class failure")

        audio.failNextStart = true
        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .idle)
        XCTAssertFalse(controller.showsNetworkErrorBanner, "a mic capture failure is not a network failure - the stale banner must not survive it")
    }

    // MARK: - Review round 5, finding B3 (blocking): auth wins over a
    // pending end-grace-wait.

    func test_authErrorDuringTheGraceWaitWinsAndIsNeverOverwrittenByThePendingEnd() {
        let scheduler = ManualScheduler()
        let (controller, _, session, _) = makeController(scheduler: scheduler)
        controller.primaryButtonTapped() // -> listening
        session.onDisconnected?()
        controller.endSession() // begins the 3s grace wait

        session.onAuthError?() // a rejected key arrives DURING the wait

        XCTAssertEqual(controller.state, .authError)
        XCTAssertEqual(session.endImmediatelyCount, 1)

        scheduler.drainAll() // the grace wait's own scheduled closure fires

        XCTAssertEqual(controller.state, .authError, "the pending end must never overwrite auth - it would lose the banner and leave the rejected key in Keychain with no way to remove it")
        XCTAssertEqual(session.endCount, 0, "the pending end must become a complete no-op once auth has already handled ending the session")
    }

    // MARK: - Review round 5, finding B4 (blocking): pause/resume during a
    // reconnect must return to the TRUE underlying state, and must not be
    // possible at all during the end grace wait.

    func test_resumeAfterPauseDuringReconnectingReturnsToReconnectingNotListening() {
        let (controller, _, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        session.onDisconnected?()
        XCTAssertEqual(controller.state, .reconnecting)

        controller.primaryButtonTapped() // Tạm dừng
        XCTAssertEqual(controller.state, .paused)
        controller.primaryButtonTapped() // Tiếp tục

        XCTAssertEqual(controller.state, .reconnecting, "resuming before the connection actually comes back must not silently claim it did")
    }

    func test_resumeAfterPauseDuringGenuineListeningStillReturnsToListening() {
        let (controller, _, _, _) = makeController()
        controller.primaryButtonTapped() // -> listening

        controller.primaryButtonTapped() // Tạm dừng
        XCTAssertEqual(controller.state, .paused)
        controller.primaryButtonTapped() // Tiếp tục

        XCTAssertEqual(controller.state, .listening, "resuming a pause that happened while genuinely connected must still return to listening")
    }

    func test_primaryButtonIsInertDuringTheEndGraceWait() {
        let scheduler = ManualScheduler()
        let (controller, audio, session, _) = makeController(scheduler: scheduler)
        controller.primaryButtonTapped() // -> listening
        session.onDisconnected?()
        controller.endSession() // begins the 3s grace wait
        XCTAssertTrue(controller.isEndPending)

        controller.primaryButtonTapped() // Tạm dừng must be inert during the wait

        XCTAssertEqual(controller.state, .reconnecting, "pause must not be possible during the end grace wait")
        XCTAssertEqual(audio.startCount, 1, "no mic restart must happen either")
    }

    /// Review round 5, finding 7 (blocking): `canEnd` must also be `false`
    /// during the wait, or "Kết thúc" stays tappable and can reopen
    /// `EndSessionSheet` mid-wait.
    func test_canEndIsFalseDuringTheEndGraceWaitSoKetThucCannotReopenTheSheet() {
        let scheduler = ManualScheduler()
        let (controller, _, session, _) = makeController(scheduler: scheduler)
        controller.primaryButtonTapped() // -> listening
        session.onDisconnected?()
        XCTAssertTrue(controller.canEnd, "sanity: Kết thúc is reachable before it is ever tapped")

        controller.endSession()

        XCTAssertFalse(controller.canEnd, "Kết thúc must become unreachable for the duration of the grace wait")

        scheduler.drainAll()
        XCTAssertFalse(controller.canEnd, "and stay unreachable once genuinely ended")
    }
}
