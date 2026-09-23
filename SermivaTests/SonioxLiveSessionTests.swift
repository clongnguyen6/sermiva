import XCTest
@testable import Sermiva

/// Covers `SonioxLiveSession`'s reconnect/retry policy - socket generation,
/// stale-event filtering, the single retry timer, backoff, the audio
/// buffer, auth precedence, and socket ownership/teardown - plus the
/// on-device `me -> target` translation queue (`makeTranslationRequests`/
/// `reportTranslation...`) it also exposes. This is app-owned logic, not
/// Soniox's wire shape or Apple's Translation framework: everything here
/// goes through `SonioxSocketConnecting`'s `FakeSonioxSocketConnection`,
/// never through `SonioxStreamSocket`, no Soniox JSON, no fixtures of the
/// wire format - the boundary AGENTS.md requires. The translation side is
/// driven the same way `ConversationView`'s `.translationTask` closure
/// would, but with a fake translated string instead of a real
/// `TranslationSession`, per the outcome's narrow-interface requirement.
/// `ManualScheduler` replaces real time, so every test runs instantly and
/// deterministically.
@MainActor
final class SonioxLiveSessionTests: XCTestCase {
    private let config = SonioxSessionConfig(apiKey: "sx_test_key_not_real", meLanguage: "vi", targetLanguage: "en", guestHint: nil)

    private func makeSession() -> (session: SonioxLiveSession, factory: FakeSonioxSocketFactory, scheduler: ManualScheduler) {
        let factory = FakeSonioxSocketFactory()
        let scheduler = ManualScheduler()
        let session = SonioxLiveSession(makeSocket: factory.make, scheduler: scheduler)
        return (session, factory, scheduler)
    }

    /// Starts the session and completes the initial handshake (the socket
    /// reports its config sent) - the common starting point most tests
    /// below build on.
    @discardableResult
    private func startAndEstablish(_ session: SonioxLiveSession, factory: FakeSonioxSocketFactory) -> Bool {
        var started = false
        session.start(config: config) { ok in started = ok }
        // The socket THIS call just created - not necessarily the first
        // index, since a session object can be reused for a later "Phien moi".
        factory.createdSockets.last?.simulateConfigSent()
        return started
    }

    func test_startSucceedsOnceTheSocketReportsConfigSent() {
        let (session, factory, _) = makeSession()
        let ok = startAndEstablish(session, factory: factory)

        XCTAssertTrue(ok)
        XCTAssertEqual(factory.createdSockets.count, 1)
    }

    // MARK: - Finding 1: overlapping retries

    /// A stale event from a socket already superseded by a LATER retry must
    /// be ignored.
    func test_staleEventFromAnAlreadySupersededSocketIsIgnored() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed()
        scheduler.drainOnce() // retry fires, socket 2 created
        XCTAssertEqual(factory.createdSockets.count, 2)

        // A very late event from socket 1 (already superseded) arrives.
        factory.createdSockets[0].simulateClosed()

        XCTAssertEqual(scheduler.pending.count, 0, "a stale event from an already-superseded socket must not schedule anything")
    }

    /// A replacement socket itself failing before it ever connects must
    /// retry again, not get stuck.
    func test_replacementSocketFailingBeforeConnectingRetriesAgain() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed()
        scheduler.drainOnce() // socket 2 created, not yet connected
        XCTAssertEqual(factory.createdSockets.count, 2)

        factory.createdSockets[1].simulateClosed() // socket 2 fails too

        XCTAssertEqual(scheduler.pending.count, 1, "a failed replacement socket must schedule exactly one more retry")
        scheduler.drainOnce()
        XCTAssertEqual(factory.createdSockets.count, 3, "a third socket must be opened")
        XCTAssertTrue(factory.createdSockets[1].isClosed)
    }

    func test_endDuringBackoffStopsTheRetryFromFiring() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateClosed()
        XCTAssertEqual(scheduler.pending.count, 1)

        var ended = false
        session.end { ended = true }
        scheduler.drainAll()

        XCTAssertTrue(ended)
        XCTAssertEqual(factory.createdSockets.count, 1, "a retry pending when the session ends must never open a new socket")
    }

    func test_pauseDuringBackoffDoesNotInterfereWithThePendingRetry() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateClosed()
        XCTAssertEqual(scheduler.pending.count, 1)

        session.beginPauseKeepalive() // must not crash even with no socket open
        session.endPauseKeepalive()

        scheduler.drainOnce()
        XCTAssertEqual(factory.createdSockets.count, 2, "pausing mid-backoff must not cancel or duplicate the pending retry")
    }

    /// An auth rejection wins at any point, including from a socket this
    /// class has already superseded - and, once the consumer reacts to it
    /// the same way `LiveSessionController` does (ending the session
    /// immediately), a pending retry must never go on to open a new socket.
    func test_authRejectedDuringBackoffWinsAndStopsThePendingRetry() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateClosed()
        XCTAssertEqual(scheduler.pending.count, 1)

        session.onAuthError = { [weak session] in
            session?.endImmediately { }
        }
        factory.createdSockets[0].simulateAuthRejected() // from the already-superseded socket

        scheduler.drainAll()
        XCTAssertEqual(factory.createdSockets.count, 1, "an auth rejection must stop the pending retry from ever opening a new socket")
    }

    /// Re-review finding 1: the Reviewer's exact reproduction. A stale
    /// auth event arriving after the session has already ended must not
    /// resurrect it into an auth error.
    func test_authRejectedAfterEndIsIgnored() {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)

        var authErrorCount = 0
        session.onAuthError = { authErrorCount += 1 }

        session.endImmediately { }
        factory.createdSockets[0].simulateAuthRejected()

        XCTAssertEqual(authErrorCount, 0, "a stale auth event after the session has ended must not resurrect it")
    }

    /// The session object is reused for "Phiên mới" (a brand-new `start`
    /// call). A straggler auth event from the PREVIOUS, already-ended
    /// session must not leak into the new one.
    func test_authRejectedFromAPreviousSessionDoesNotLeakIntoANewOne() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory) // session 1: socket 0

        var ended = false
        session.end { ended = true }
        scheduler.drainAll()
        XCTAssertTrue(ended)

        var authErrorCount = 0
        session.onAuthError = { authErrorCount += 1 }
        startAndEstablish(session, factory: factory) // session 2 (Phien moi): socket 1

        // A very late straggler from session 1's original socket arrives.
        factory.createdSockets[0].simulateAuthRejected()

        XCTAssertEqual(authErrorCount, 0, "a stale auth event from a previous, already-ended session must not leak into a new one")
    }

    // MARK: - Finding 2: the audio buffer across a multi-attempt outage

    /// Audio captured across a WHOLE outage - including during a failed
    /// attempt in the middle of it - must all reach the socket that finally
    /// succeeds, not be discarded by any attempt that failed along the way.
    func test_bufferedAudioPersistsAcrossFailedRetryAttemptsWithinOneOutage() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed() // outage begins
        session.ingestAudio(Data(repeating: 1, count: 100))
        scheduler.drainOnce() // retry 1 fires, socket 1 created, not yet connected
        session.ingestAudio(Data(repeating: 2, count: 100))

        factory.createdSockets[1].simulateClosed() // socket 1 also fails before connecting
        scheduler.drainOnce() // retry 2 fires, socket 2 created

        factory.createdSockets[2].simulateConfigSent()

        XCTAssertEqual(factory.createdSockets[2].sentAudioChunks.count, 2, "audio captured across the whole outage must not be discarded by a failed attempt in between")
    }

    /// Once actually flushed to a socket that connected, the buffer is
    /// empty again - a LATER, separate outage starts from nothing, not
    /// from whatever the previous outage happened to buffer.
    func test_bufferedAudioClearsOnceFlushedAndDoesNotCarryIntoALaterSeparateOutage() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed()
        session.ingestAudio(Data(repeating: 1, count: 100))
        scheduler.drainOnce()
        factory.createdSockets[1].simulateConfigSent()
        XCTAssertEqual(factory.createdSockets[1].sentAudioChunks.count, 1)

        // A second, separate outage.
        factory.createdSockets[1].simulateClosed()
        scheduler.drainOnce()
        factory.createdSockets[2].simulateConfigSent()

        XCTAssertEqual(factory.createdSockets[2].sentAudioChunks.count, 0, "a later, separate outage must not replay the previous outage's already-flushed audio")
    }

    /// Re-review finding 3: ending mid-outage is the obvious choice for
    /// what buffered-but-never-sent audio means - it stops meaning
    /// anything once the session it was captured for is over. Buffers
    /// audio BEFORE the new session's socket reports ready, so the new
    /// session's own flush is what is actually being checked here, not
    /// just direct passthrough.
    func test_endingMidOutageClearsTheBufferSoALaterSessionDoesNotReplayIt() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed()
        session.ingestAudio(Data(repeating: 1, count: 100)) // buffered during the outage

        var ended = false
        session.end { ended = true }
        scheduler.drainAll()
        XCTAssertTrue(ended)

        // A new session (Phien moi, reusing this object) - its own audio
        // arrives before its socket has connected, so it goes through the
        // buffer too.
        var started = false
        session.start(config: config) { ok in started = ok }
        session.ingestAudio(Data(repeating: 2, count: 100))
        factory.createdSockets.last?.simulateConfigSent()
        XCTAssertTrue(started)

        XCTAssertEqual(factory.createdSockets[1].sentAudioChunks.count, 1, "only the new session's own buffered audio may be flushed, never the previous ended session's leftover buffer")
    }

    // MARK: - Reviewer finding, fourth round: end/endImmediately must
    // abandon any still-in-progress non-me M-direct translation, exactly
    // like a reconnect already does, so the internal state stays honest
    // rather than silently depending on the server's own `<fin>` arriving
    // before `close()`.

    private func nonMeSegmentResponseTokens() -> [SonioxToken] {
        [
            SonioxToken(text: "Hi", isFinal: true, startMs: 0, endMs: 1000, speaker: "1", language: "en", translationStatus: .original),
            SonioxToken(text: "Ch", isFinal: false, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .translation),
            SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .original),
        ]
    }

    func test_endAbandonsAStillInProgressNonMeTranslationSoInternalStateStaysHonest() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        // M starts a non-me segment's translation but never finishes it.
        factory.createdSockets[0].simulateResponse(tokens: nonMeSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }

        var ended = false
        session.end { ended = true }
        scheduler.drainAll()

        XCTAssertTrue(ended)
        XCTAssertEqual(lastSegments.count, 1)
        XCTAssertTrue(lastSegments[0].targetAbandoned, "end must abandon a still in-progress M-direct translation, same as reconnect does")
    }

    func test_endImmediatelyAbandonsAStillInProgressNonMeTranslationSoInternalStateStaysHonest() {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateResponse(tokens: nonMeSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }

        var ended = false
        session.endImmediately { ended = true }

        XCTAssertTrue(ended)
        XCTAssertEqual(lastSegments.count, 1)
        XCTAssertTrue(lastSegments[0].targetAbandoned, "endImmediately must abandon a still in-progress M-direct translation, same as reconnect does")
    }

    // MARK: - On-device me -> target translation queue

    private func meSegmentResponseTokens(text: String = "Xin chào") -> [SonioxToken] {
        [
            SonioxToken(text: text, isFinal: true, startMs: 0, endMs: 1000, speaker: "1", language: "vi", translationStatus: .original),
            SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .original),
        ]
    }

    /// Drives `makeTranslationRequests()` the same way `ConversationView`'s
    /// `.translationTask` closure does: a `for await` loop, one request at
    /// a time, reporting back by id - but with a fake translated string
    /// instead of a real `TranslationSession`.
    private func drainOneTranslationRequest(
        from session: SonioxLiveSession,
        onStarted: (Int) -> Void = { _ in },
        respond: (Int, String) -> Void
    ) async {
        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        guard let request = await iterator.next() else { return }
        onStarted(request.id)
        session.reportTranslationStarted(id: request.id)
        respond(request.id, request.source)
    }

    func test_onlyFinalMeSegmentsAreSentInOrderOneAtATime() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens(text: "Xin chào"))
        factory.createdSockets[0].simulateResponse(tokens: [
            SonioxToken(text: "Hi", isFinal: true, startMs: 1000, endMs: 1500, speaker: "1", language: "en", translationStatus: .original),
            SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .original),
        ]) // a non-me segment must never be sent for on-device translation
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens(text: "Tạm biệt"))

        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        let first = await iterator.next()
        XCTAssertEqual(first?.source, "Xin chào")
        XCTAssertFalse(lastSegments[0].translationInProgress, "queued alone (not yet started) must not show the indicator")

        let second = await iterator.next()
        XCTAssertEqual(second?.source, "Tạm biệt", "the two me segments must arrive in order, with the non-me segment never sent at all")
    }

    func test_indicatorIsOnOnlyWhileTranslationIsActuallyInFlight() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }

        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        let request = await iterator.next()!
        session.reportTranslationStarted(id: request.id)
        XCTAssertTrue(lastSegments[0].translationInProgress, "must be on the instant translation actually starts")

        session.reportTranslationSuccess(id: request.id, target: "Hello")
        XCTAssertFalse(lastSegments[0].translationInProgress, "must clear once the result lands")
    }

    func test_successWritesTheWholeTargetOnce() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }
        await drainOneTranslationRequest(from: session) { id, _ in
            session.reportTranslationSuccess(id: id, target: "Hello")
        }

        XCTAssertEqual(lastSegments[0].target, "Hello")
        XCTAssertFalse(lastSegments[0].targetAbandoned)
    }

    /// An error means "no translation" - never retried automatically.
    func test_failureAbandonsWithNoRetry() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }
        await drainOneTranslationRequest(from: session) { id, _ in
            session.reportTranslationFailure(id: id)
        }

        XCTAssertNil(lastSegments[0].target)
        XCTAssertTrue(lastSegments[0].targetAbandoned)

        // A stray later success for the same (already-abandoned) id must
        // never resurrect it.
        let firstRequestId = 1
        session.reportTranslationSuccess(id: firstRequestId, target: "too late")
        XCTAssertNil(lastSegments[0].target, "a report for an already-retired request id must be ignored")
    }

    /// Stream termination (the view disappearing, or the task cancelled)
    /// abandons whatever is still queued or in-flight and clears the
    /// indicator - exercised here by letting the returned `AsyncStream`
    /// deinitialize, which fires `onTermination`.
    func test_streamTerminationAbandonsQueuedAndInFlightRequestsAndClearsIndicators() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }

        do {
            var iterator = session.makeTranslationRequests().makeAsyncIterator()
            let request = await iterator.next()!
            session.reportTranslationStarted(id: request.id)
            XCTAssertTrue(lastSegments[0].translationInProgress, "sanity: genuinely in flight")
        }
        // `iterator`'s stream is now unreachable; `AsyncStream`'s
        // `onTermination` fires once it deinitializes, hopping back to the
        // main actor (`MeTranslationQueue`'s own doc comment) - so this
        // test yields until that hop has actually run, rather than
        // asserting immediately against a race.
        for _ in 0..<20 where !lastSegments[0].targetAbandoned {
            await Task.yield()
        }

        XCTAssertTrue(lastSegments[0].targetAbandoned, "stream termination must abandon an in-flight request")
        XCTAssertFalse(lastSegments[0].translationInProgress, "and clear its indicator")
    }

    /// A cross-session id-reuse guard: a stale in-flight request from a
    /// session that has already ended (and been abandoned) must never land
    /// on a same-numbered segment id in the very next "Phiên mới".
    func test_aStaleReportFromAnEndedSessionNeverLandsOnTheNextSessionsSameNumberedSegment() async {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }
        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        let staleRequest = await iterator.next()!
        session.reportTranslationStarted(id: staleRequest.id)

        session.end { }
        scheduler.drainAll()

        // "Phiên mới": a fresh session, fresh SonioxJoinEngine - segment ids
        // restart at 1, colliding numerically with the ended session's own
        // segment 1.
        startAndEstablish(session, factory: factory)
        factory.createdSockets.last?.simulateResponse(tokens: meSegmentResponseTokens(text: "New session"))

        // The stale request's own (very late) completion arrives.
        session.reportTranslationSuccess(id: staleRequest.id, target: "stale translation")

        XCTAssertNotEqual(lastSegments[0].target, "stale translation", "a stale cross-session report must never corrupt the new session's same-numbered segment")
        XCTAssertNil(lastSegments[0].target)
    }
}
