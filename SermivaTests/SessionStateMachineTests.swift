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
            isDemo: true,
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

    /// C1: a capture failure is not a permission denial, and must not stop
    /// the one concrete outcome this slice exists to prove - the demo plays
    /// the sample conversation - from happening. It only makes the mic line
    /// honestly report itself as off.
    func test_captureFailureStillPlaysBackTheFixtureWithMicReportedOff() {
        let audio = FakeAudioCapture()
        audio.failNextStart = true
        let (controller, _, scheduler, _) = makeController(audio: audio)

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .listening, "a capture failure must not stop the demo from playing")
        XCTAssertFalse(controller.isMicCapturing, "the mic line must honestly report that capture did not open")
        XCTAssertEqual(controller.segments.count, 1, "the fixture must still be advancing")

        scheduler.drainAll()

        XCTAssertEqual(controller.segments.count, 2, "playback must run to completion even though the mic never opened")
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

        XCTAssertFalse(controller.isMicCapturing)
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
            isDemo: true,
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

    // MARK: - Project owner decision: demo never opens real mic I/O

    /// With no fakes injected - the exact wiring `ConversationView` uses -
    /// the demo must still play, and must never claim to be capturing.
    func test_productionDefaultsNeverOpenRealCaptureButStillPlayTheDemo() {
        let scheduler = ManualScheduler()
        let controller = DemoSessionController(
            events: makeEvents(),
            isDemo: true,
            scheduler: scheduler,
            eventInterval: 0.01,
            translationDelay: 0.01
        )

        controller.primaryButtonTapped()

        XCTAssertEqual(controller.state, .listening, "the production demo must still play even though it never opens real capture")
        XCTAssertFalse(controller.isMicCapturing, "demo must never claim to be capturing - it never asks for or opens real audio")
        XCTAssertEqual(controller.segments.count, 1)
    }

    // MARK: - C1: mic display follows real capture, not session state

    func test_isMicCapturingTracksRealCaptureThroughPauseResumeAndEnd() {
        let (controller, _, _, _) = makeController()
        XCTAssertFalse(controller.isMicCapturing)

        controller.primaryButtonTapped() // -> listening
        XCTAssertTrue(controller.isMicCapturing)

        controller.primaryButtonTapped() // -> paused
        XCTAssertFalse(controller.isMicCapturing)

        controller.primaryButtonTapped() // -> listening again
        XCTAssertTrue(controller.isMicCapturing)

        controller.endSession()
        XCTAssertFalse(controller.isMicCapturing)
    }

    /// Live (isDemo: false) path: the dock text is a pure function of
    /// `(isMicCapturing, state)`, not of `state` alone - `isMicCapturing:
    /// true` must say "Dang nghe" no matter what `state` is, with one
    /// deliberate exception: `.reconnecting` (see the dedicated test right
    /// below), where HANDOFF section 5 defines "Mic giữ, chờ mạng"
    /// specifically for a mic that is still capturing while the network is
    /// down. `listening` with capture off falls back to "Mic tat" - the
    /// one string among the six that stays true when the session is
    /// genuinely running but the mic never opened. This branch is not
    /// reachable by the shipped demo (see the isDemo test below); it is
    /// kept for Outcome 2's real session.
    func test_micDockTextFollowsCaptureNotSession() {
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: true, state: .paused, isDemo: false), "Đang nghe")
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: true, state: .idle, isDemo: false), "Đang nghe")
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: true, state: .micDenied, isDemo: false), "Đang nghe")

        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: false, state: .listening, isDemo: false), "Mic tắt", "session running with capture off must not claim any of the other five strings")
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: false, state: .idle, isDemo: false), "Mic tắt")
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: false, state: .paused, isDemo: false), "Đã tạm dừng")
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: false, state: .requestingMic, isDemo: false), "Đang mở mic…")
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: false, state: .connecting, isDemo: false), "Đang mở mic…")
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: false, state: .micDenied, isDemo: false), "Chưa có quyền mic")
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: false, state: .reconnecting, isDemo: false), "Mic giữ, chờ mạng")
    }

    /// The real live scenario finding 5 flagged: the mic is never stopped
    /// for a network-only reconnect (HANDOFF: "mic giữ quyền"), so
    /// `isMicCapturing` is `true` the whole time - the dock must still say
    /// "Mic giữ, chờ mạng", not silently fall back to "Đang nghe" as if the
    /// network were fine.
    func test_micDockTextShowsMicHeldWaitingForNetworkDuringReconnectEvenWhileCapturing() {
        XCTAssertEqual(DemoSessionController.micDockText(isMicCapturing: true, state: .reconnecting, isDemo: false), "Mic giữ, chờ mạng")
    }

    /// Project owner's decision: in demo there is nothing capturing under
    /// any session state, so the dock must say "Mic tat" everywhere,
    /// including "asking"/"paused" states that would otherwise imply a mic
    /// that was at some point open. Checked for every SessionState case,
    /// and even for a (never actually possible in demo) isMicCapturing:
    /// true, since the demo flag must win outright, not just tip the
    /// existing six-string mapping.
    func test_demoAlwaysShowsMicOffRegardlessOfSessionState() {
        let allStates: [SessionState] = [
            .idle, .requestingMic, .micDenied, .connecting, .listening,
            .paused, .reconnecting, .authError, .ended,
        ]
        for state in allStates {
            XCTAssertEqual(
                DemoSessionController.micDockText(isMicCapturing: false, state: state, isDemo: true),
                "Mic tắt",
                "demo must always show Mic tat, state: \(state)"
            )
            XCTAssertEqual(
                DemoSessionController.micDockText(isMicCapturing: true, state: state, isDemo: true),
                "Mic tắt",
                "demo must show Mic tat even if capture were somehow reported on, state: \(state)"
            )
        }
    }

    // MARK: - E2: `isDemo` lives on the controller itself (a single source),
    // and `ConversationView` reads these precomputed instance properties
    // rather than passing its own copy of the flag at each call site. These
    // tests exercise exactly what the view reads, not just the pure static
    // helpers above, so a regression at that single source - not only a
    // regression in the pure functions - turns one of these red.

    func test_instanceMicDockTextStaysMicOffThroughDemoRegardlessOfState() {
        let (controller, _, scheduler, _) = makeController()
        XCTAssertEqual(controller.micDockText, "Mic tắt")

        controller.primaryButtonTapped() // -> listening
        XCTAssertEqual(controller.micDockText, "Mic tắt", "listening must not flip demo's mic dock text")

        controller.primaryButtonTapped() // -> paused
        XCTAssertEqual(controller.micDockText, "Mic tắt")

        scheduler.drainAll()
    }

    func test_instanceMicDotColorRoleStaysNeutralThroughDemoRegardlessOfState() {
        let (controller, _, scheduler, _) = makeController()
        XCTAssertEqual(controller.micDotColorRole, .neutral)

        controller.primaryButtonTapped() // -> listening; a real capture would report .live here
        XCTAssertEqual(controller.micDotColorRole, .neutral, "demo must never show the live dot color, even while listening")

        scheduler.drainAll()
    }

    func test_instanceMicIconNameStaysMicSlashThroughDemoRegardlessOfState() {
        let (controller, _, scheduler, _) = makeController()
        XCTAssertEqual(controller.micIconName, "mic.slash")

        controller.primaryButtonTapped() // -> listening; a real capture would report mic.fill here
        XCTAssertEqual(controller.micIconName, "mic.slash", "demo must never show the mic.fill icon, even while listening")

        scheduler.drainAll()
    }

    func test_instanceEndSessionBodyTextDropsTheMicClauseInDemo() {
        let (controller, _, _, _) = makeController()
        XCTAssertEqual(
            controller.endSessionBodyText,
            "Bản ghi vẫn xem lại được cho đến khi bạn bắt đầu phiên mới.",
            "the End Session sheet body the controller hands to the view must already have the mic clause dropped in demo"
        )
    }

    // MARK: - K1: an activity indicator (the "Dang nhan dang" tag, its
    // pulsing dot, the caret, "Dang dich..." and its spinner) only shows
    // while that activity is genuinely running - not as a stale readout of
    // a segment's own shape (`isFinal`/`target`) once the session has
    // stopped advancing.

    func test_isActivityRunningIsTrueOnlyWhileListening() {
        let allStates: [SessionState] = [
            .idle, .requestingMic, .micDenied, .connecting, .listening,
            .paused, .reconnecting, .authError, .ended,
        ]
        for state in allStates {
            XCTAssertEqual(
                DemoSessionController.isActivityRunning(for: state),
                state == .listening,
                "isActivityRunning must be true for .listening only, state: \(state)"
            )
        }
    }

    /// Drives the real flow with a partial (non-final) segment still
    /// current, exactly the shape the project owner's review found showing
    /// a stale "Dang nhan dang" while paused: `isActivityRunning` must
    /// track session state, not the segment's own `isFinal`, which stays
    /// false throughout since nothing here ever completes it.
    func test_isActivityRunningTracksPauseAndEndWhileASegmentStaysPartial() {
        let (controller, _, scheduler, _) = makeController()
        XCTAssertFalse(controller.isActivityRunning)

        controller.primaryButtonTapped() // -> listening, applies event 1 (a partial)
        XCTAssertFalse(controller.segments[0].isFinal, "the fixture's first event is a partial, not yet final")
        XCTAssertTrue(controller.isActivityRunning, "genuinely listening: the indicator may show")

        controller.primaryButtonTapped() // -> paused, segment still partial
        XCTAssertFalse(controller.segments[0].isFinal)
        XCTAssertFalse(controller.isActivityRunning, "paused: the partial's indicator must not claim ongoing activity")

        controller.primaryButtonTapped() // -> listening again
        XCTAssertTrue(controller.isActivityRunning)

        controller.endSession()
        XCTAssertFalse(controller.isActivityRunning, "ended: nothing is running any more")

        scheduler.drainAll()
    }

    // MARK: - L1: simulated translation is part of the session, not a
    // background process that outlives it - it stops and resumes with
    // pause/resume/end/"Phien moi", the same as the demo playback it comes
    // from.

    func test_pendingTranslationDoesNotLandWhilePaused() {
        let (controller, _, scheduler, _) = makeController()
        controller.primaryButtonTapped() // -> listening, applies event 1 (partial id 1)
        scheduler.drainOnce() // fires the queued advance -> applies final id 1, schedules its translation
        XCTAssertTrue(controller.segments[0].isFinal)
        XCTAssertNil(controller.segments[0].target)

        controller.primaryButtonTapped() // -> paused
        scheduler.drainAll() // fires the translation scheduled before the pause, among others

        XCTAssertNil(controller.segments[0].target, "a translation scheduled before pause must not land while paused")
    }

    func test_resumeReschedulesAnInterruptedTranslationWithAFreshDelay() {
        let (controller, _, scheduler, _) = makeController()
        controller.primaryButtonTapped() // -> listening, applies event 1 (partial id 1)
        scheduler.drainOnce() // -> final id 1 applied, translation scheduled
        XCTAssertNil(controller.segments[0].target)

        controller.primaryButtonTapped() // -> paused
        scheduler.drainAll() // the interrupted translation must not land here
        XCTAssertNil(controller.segments[0].target)

        controller.primaryButtonTapped() // -> listening again: resume must reschedule it
        scheduler.drainAll()

        XCTAssertEqual(
            controller.segments[0].target,
            finalTargetForSegment1(),
            "resume must reschedule a translation interrupted by pause, not leave it stuck forever"
        )
    }

    func test_endSessionCancelsAPendingTranslationPermanently() {
        let (controller, _, scheduler, _) = makeController()
        controller.primaryButtonTapped() // -> listening, applies event 1 (partial id 1)
        scheduler.drainOnce() // -> final id 1 applied, translation scheduled
        XCTAssertNil(controller.segments[0].target)

        controller.endSession()
        scheduler.drainAll() // the pending translation must not land after ending

        XCTAssertEqual(controller.state, .ended)
        XCTAssertNil(controller.segments[0].target, "ending the session must cancel a pending translation, not let it land later")
    }

    /// The exact shape the project owner's review reproduced: a translation
    /// scheduled by a previous session, still sitting in the scheduler
    /// queue when "Phien moi" starts a new session that reuses the same
    /// segment id, must not land on that new session's fresh partial.
    func test_newSessionDoesNotReceiveThePreviousSessionsPendingTranslation() {
        let (controller, _, scheduler, _) = makeController()
        controller.primaryButtonTapped() // -> listening, session 1
        scheduler.drainOnce() // -> session 1's final id 1 applied, its translation scheduled (not yet fired)

        controller.endSession()
        controller.primaryButtonTapped() // "Phien moi": fresh session 2, new partial id 1

        XCTAssertFalse(controller.segments[0].isFinal, "session 2's first segment is a fresh partial, not session 1's old final")
        XCTAssertNil(controller.segments[0].target)

        // Fire session 1's stale translation closure directly - it is still
        // sitting first in the queue, scheduled before "endSession" and
        // never removed, just no longer matching the current token.
        let staleTranslation = scheduler.pending[0]
        staleTranslation()

        XCTAssertNil(controller.segments[0].target, "a previous session's pending translation must not land on a new session's partial reusing the same id")
        XCTAssertFalse(controller.segments[0].isFinal, "firing the stale translation must not affect isFinal either")
    }

    // MARK: - L2: `controller.displaySegments` is what `CaptionsTranscriptView`
    // actually reads - a regression there, not only in `SegmentDisplay.make`
    // itself, must turn this red too.

    func test_instanceDisplaySegmentsHideIndicatorsWhilePausedOnAStillPartialSegment() {
        let (controller, _, scheduler, _) = makeController()
        controller.primaryButtonTapped() // -> listening, applies event 1 (a partial)
        XCTAssertEqual(controller.displaySegments.last?.showsRecognizingTag, true)
        XCTAssertEqual(controller.displaySegments.last?.showsCaret, true)

        controller.primaryButtonTapped() // -> paused, segment still partial
        XCTAssertEqual(controller.displaySegments.last?.showsRecognizingTag, false, "paused must not claim recognition is running")
        XCTAssertEqual(controller.displaySegments.last?.showsCaret, false, "paused must not claim recognition is running")

        scheduler.drainAll()
    }
}
