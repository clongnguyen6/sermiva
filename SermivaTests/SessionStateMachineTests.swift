import XCTest
@testable import Sermiva

/// Covers the section-5 session state machine, including the `micDenied`
/// branch, driven through `DemoSessionController` with fakes for the
/// microphone permission prompt, audio capture and the playback clock.
@MainActor
final class SessionStateMachineTests: XCTestCase {
    /// The real `cafe_vi_en` events from `demo-data.json`, loaded once.
    private static let allCafeEvents: [DemoEvent] = try! DemoFixtureLoader.loadCafeViEnEvents(
        bundle: Bundle(for: SessionStateMachineTests.self)
    )

    /// A hand-picked subset of the real fixture, in its original order:
    /// segment 1's first partial, segment 1's final (which carries a real
    /// target string), then segment 2's first partial - enough to drive
    /// requestingMic -> listening, one final lock plus a delayed target
    /// fill, and a second distinct segment id.
    private func makeEvents() -> [DemoEvent] {
        let seg1 = Self.allCafeEvents.filter { $0.id == 1 }
        let seg2 = Self.allCafeEvents.filter { $0.id == 2 }
        return [seg1[0], seg1.last!, seg2[0]]
    }

    private func finalTargetForSegment1() -> String {
        Self.allCafeEvents.first { $0.id == 1 && $0.type == .final }!.tgt!
    }

    private func makeController(
        micGranted: Bool = true,
        audio: FakeAudioCapture = FakeAudioCapture(),
        scheduler: ManualScheduler = ManualScheduler()
    ) -> (controller: DemoSessionController, audio: FakeAudioCapture, scheduler: ManualScheduler, mic: FakeMicPermissionProvider) {
        let mic = FakeMicPermissionProvider(granted: micGranted)
        let controller = DemoSessionController(
            events: makeEvents(),
            micPermission: mic,
            audioCapture: audio,
            scheduler: scheduler,
            eventInterval: 0.01,
            translationDelay: 0.01
        )
        return (controller, audio, scheduler, mic)
    }

    func test_idleToListeningOnGrantedPermissionOpensCapture() {
        let (controller, audio, _, _) = makeController()
        XCTAssertEqual(controller.state, .idle)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(audio.startCount, 1, "listening must correspond to a genuinely open capture")
    }

    func test_deniedPermissionGoesToMicDeniedAndNeverOpensCapture() {
        let (controller, audio, _, _) = makeController(micGranted: false)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .micDenied)
        XCTAssertEqual(audio.startCount, 0)
    }

    func test_micDeniedTapRechecksPermissionAndProceedsIfNowGranted() {
        // The only way out of micDenied in the approved prototype is the
        // same "Bat dau" tap re-checking the real permission - the user
        // grants it via the banner's "Mo Cai dat iPhone" affordance, then
        // comes back and taps Bat dau again.
        let (controller, audio, _, mic) = makeController(micGranted: false)
        controller.primaryButtonTapped()
        XCTAssertEqual(controller.state, .micDenied)

        mic.granted = true
        controller.primaryButtonTapped()

        XCTAssertEqual(mic.requestCount, 2, "each tap from micDenied must re-check the real permission, not remember the old denial")
        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(audio.startCount, 1)
    }

    func test_micDeniedTapStaysDeniedIfPermissionStillNotGranted() {
        let (controller, _, _, mic) = makeController(micGranted: false)
        controller.primaryButtonTapped()
        XCTAssertEqual(controller.state, .micDenied)

        controller.primaryButtonTapped()

        XCTAssertEqual(mic.requestCount, 2)
        XCTAssertEqual(controller.state, .micDenied)
    }

    func test_audioEngineFailureReturnsToIdleWithoutMisreportingPermissionDenial() {
        let audio = FakeAudioCapture()
        audio.failNextStart = true
        let (controller, _, _, mic) = makeController(audio: audio)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .idle, "an engine failure is not a permission denial; section 5 has no dedicated mic-error state to report instead")

        // Retry: permission is already granted, so this should not need to
        // ask again in spirit, though it does re-check (harmless - the OS
        // answers instantly once already decided), and should now succeed.
        let requestsBeforeRetry = mic.requestCount
        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .listening, "a transient engine failure must not leave the controller stuck")
        XCTAssertGreaterThan(mic.requestCount, requestsBeforeRetry)
    }

    func test_pauseStopsCaptureAndHaltsPlayback() {
        let (controller, audio, scheduler, _) = makeController()
        controller.primaryButtonTapped() // idle -> listening; first event applied synchronously
        XCTAssertEqual(controller.segments.count, 1)

        controller.primaryButtonTapped() // listening -> paused
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(audio.stopCount, 1)

        scheduler.drainAll()
        XCTAssertEqual(controller.segments.count, 1, "playback must not advance while paused")
    }

    func test_resumeContinuesPlaybackWithoutResettingSegments() {
        let (controller, audio, scheduler, _) = makeController()
        controller.primaryButtonTapped() // -> listening, event 1 applied
        controller.primaryButtonTapped() // -> paused
        controller.primaryButtonTapped() // -> listening again

        XCTAssertEqual(controller.state, .listening)
        XCTAssertEqual(audio.startCount, 2, "resume opens capture again")

        scheduler.drainAll()
        XCTAssertEqual(controller.segments.count, 2, "resume must play the remaining events, not restart")
    }

    func test_finalLocksImmediatelyButTargetWaitsForTheScheduledFill() {
        let (controller, _, scheduler, _) = makeController()
        controller.primaryButtonTapped() // -> listening, applies event 1 (partial id 1)

        scheduler.drainOnce() // fires the queued "advance" tick -> applies final id 1
        XCTAssertTrue(controller.segments[0].isFinal)
        XCTAssertNil(controller.segments[0].target, "target must not be set the instant final is applied")

        scheduler.drainOnce() // fires the queued fillTarget (and the next advance tick)
        XCTAssertEqual(controller.segments[0].target, finalTargetForSegment1())
    }

    func test_endSessionStopsCaptureThenNewSessionClearsAndRestartsPlayback() {
        let (controller, audio, _, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        XCTAssertTrue(controller.canEnd)

        controller.endSession()

        XCTAssertEqual(controller.state, .ended)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertFalse(controller.canEnd)

        controller.primaryButtonTapped() // ended -> "Phien moi": clears the transcript and restarts the flow, per the approved prototype

        XCTAssertEqual(controller.state, .listening, "Phien moi does not stop at idle waiting for a second tap")
        XCTAssertEqual(controller.segments.count, 1, "the transcript was cleared, then playback restarted from the first event")
        XCTAssertEqual(controller.segments.first?.id, 1)
        XCTAssertEqual(audio.startCount, 2)
    }

    func test_canEndIsFalseInIdleAndTrueOnceASessionHasStarted() {
        let (controller, _, _, _) = makeController()
        XCTAssertFalse(controller.canEnd)

        controller.primaryButtonTapped()

        XCTAssertTrue(controller.canEnd)
    }

    // MARK: - S1: reconnecting (pure mapping, since nothing in this offline
    // slice can produce the network signal that would actually reach it)

    func test_reconnectingMapsToPauseAndAllowsEnding() {
        XCTAssertTrue(DemoSessionController.canEnd(for: .reconnecting), "a reconnecting session is still running: Ket thuc must stay reachable")
    }

    // MARK: - B2: capture stopping for a reason outside an explicit pause

    func test_externalCaptureStopWhileListeningFallsBackToPausedNotStaleListening() {
        let (controller, audio, scheduler, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        XCTAssertEqual(controller.state, .listening)

        audio.simulateExternalStop() // e.g. backgrounding, a call, media services reset

        XCTAssertEqual(controller.state, .paused, "the dock must never keep saying 'Dang nghe' once capture has stopped for a reason outside the user's own pause tap")

        scheduler.drainAll()
        XCTAssertEqual(controller.segments.count, 1, "playback must halt too, same as an explicit pause")
    }

    func test_externalStopSignalWhileAlreadyPausedIsANoOp() {
        // The real capture only ever reports an unexpected stop while it
        // was actually running. A stray/duplicate callback arriving after
        // the user has already paused (capture already stopped on purpose)
        // must not re-trigger anything or move the state.
        let (controller, audio, _, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        controller.primaryButtonTapped() // -> paused
        XCTAssertEqual(controller.state, .paused)

        audio.simulateExternalStop()

        XCTAssertEqual(controller.state, .paused)
    }

    func test_deinitStopsCaptureIfStillOpen() {
        let audio = FakeAudioCapture()
        var controller: DemoSessionController? = DemoSessionController(
            events: makeEvents(),
            micPermission: FakeMicPermissionProvider(granted: true),
            audioCapture: audio,
            scheduler: ManualScheduler(),
            eventInterval: 0.01,
            translationDelay: 0.01
        )
        controller?.primaryButtonTapped()
        XCTAssertEqual(audio.startCount, 1)

        controller = nil

        XCTAssertEqual(audio.stopCount, 1, "dropping the controller from the view tree must stop capture, not leave the mic open")
    }
}
