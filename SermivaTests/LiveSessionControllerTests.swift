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
        translationAvailability: FakeMeToTargetAvailabilityChecker = FakeMeToTargetAvailabilityChecker()
    ) -> (controller: LiveSessionController, audio: FakeAudioCapture, session: FakeSonioxLiveSession, mic: FakeMicPermissionProvider) {
        let mic = FakeMicPermissionProvider(granted: micGranted)
        let controller = LiveSessionController(
            apiKey: "sx_test_key_not_real",
            micPermission: mic,
            audioCapture: audio,
            liveSession: session,
            translationAvailability: translationAvailability
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
        XCTAssertEqual(session.endCount, 1, "a connect failure must not leave the other socket billing in the background")
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
        XCTAssertEqual(session.startCount, 0, "a startup capture failure must not open the metered Soniox sockets at all")
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
}
