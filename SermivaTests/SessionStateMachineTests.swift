import XCTest
@testable import Sermiva

/// Covers the section-5 session state machine, including the `micDenied`
/// branch, driven through `DemoSessionController` with fakes for the
/// microphone permission prompt, audio capture and the playback clock.
@MainActor
final class SessionStateMachineTests: XCTestCase {
    private func makeEvents() -> [DemoEvent] {
        [
            DemoEvent(type: .partial, id: 1, speaker: "A", lang: "vi", src: "Cho tôi", tgt: nil, overlap: nil),
            DemoEvent(type: .final, id: 1, speaker: nil, lang: nil, src: "Cho tôi một cà phê.", tgt: "I'd like a coffee.", overlap: nil),
            DemoEvent(type: .partial, id: 2, speaker: "B", lang: "en", src: "Would you like", tgt: nil, overlap: nil),
        ]
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

    func test_micDeniedIgnoresFurtherTapsWithoutReRequestingPermission() {
        let (controller, _, _, mic) = makeController(micGranted: false)
        controller.primaryButtonTapped()
        XCTAssertEqual(controller.state, .micDenied)
        let requestsSoFar = mic.requestCount

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .micDenied)
        XCTAssertEqual(mic.requestCount, requestsSoFar, "the main button is disabled while denied; it must not silently retry")
    }

    func test_audioEngineFailureFallsBackToMicDenied() {
        let audio = FakeAudioCapture()
        audio.failNextStart = true
        let (controller, _, _, _) = makeController(audio: audio)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .micDenied)
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
        XCTAssertEqual(controller.segments[0].target, "I'd like a coffee.")
    }

    func test_endSessionStopsCaptureThenNewSessionClearsSegments() {
        let (controller, audio, _, _) = makeController()
        controller.primaryButtonTapped() // -> listening
        XCTAssertTrue(controller.canEnd)

        controller.endSession()

        XCTAssertEqual(controller.state, .ended)
        XCTAssertEqual(audio.stopCount, 1)
        XCTAssertFalse(controller.canEnd)

        controller.primaryButtonTapped() // ended -> idle ("Phien moi")
        XCTAssertEqual(controller.state, .idle)
        XCTAssertTrue(controller.segments.isEmpty)
    }

    func test_canEndIsFalseInIdleAndTrueOnceASessionHasStarted() {
        let (controller, _, _, _) = makeController()
        XCTAssertFalse(controller.canEnd)

        controller.primaryButtonTapped()

        XCTAssertTrue(controller.canEnd)
    }
}
