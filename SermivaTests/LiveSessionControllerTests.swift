import XCTest
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
        session: FakeSonioxLiveSession = FakeSonioxLiveSession()
    ) -> (controller: LiveSessionController, audio: FakeAudioCapture, session: FakeSonioxLiveSession, mic: FakeMicPermissionProvider) {
        let mic = FakeMicPermissionProvider(granted: micGranted)
        let controller = LiveSessionController(
            apiKey: "sx_test_key_not_real",
            micPermission: mic,
            audioCapture: audio,
            liveSession: session
        )
        return (controller, audio, session, mic)
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

    func test_authErrorCallbackStopsCaptureAndMovesState() {
        let (controller, audio, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        XCTAssertTrue(controller.isMicCapturing)

        session.onAuthError?()

        XCTAssertEqual(controller.state, .authError)
        XCTAssertFalse(controller.isMicCapturing)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertEqual(session.endCount, 1, "a rejected key must not leave the sockets open and billing")
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

    func test_audioBufferCallbackForwardsToTheLiveSession() {
        let (controller, audio, session, _) = makeController()
        controller.primaryButtonTapped() // -> listening, wires onAudioBuffer

        audio.onAudioBuffer?(Data([0x01, 0x02]))

        XCTAssertEqual(session.ingestedAudioCount, 1)
        _ = controller
    }
}
