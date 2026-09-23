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
        let (session, factory, scheduler, _) = makeSessionWithPathMonitor()
        return (session, factory, scheduler)
    }

    private func makeSessionWithPathMonitor() -> (session: SonioxLiveSession, factory: FakeSonioxSocketFactory, scheduler: ManualScheduler, pathMonitors: FakeNetworkPathMonitorFactory) {
        let factory = FakeSonioxSocketFactory()
        let scheduler = ManualScheduler()
        let pathMonitors = FakeNetworkPathMonitorFactory()
        let session = SonioxLiveSession(makeSocket: factory.make, scheduler: scheduler, makePathMonitor: pathMonitors.make)
        return (session, factory, scheduler, pathMonitors)
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
        XCTAssertEqual(scheduler.pending.count, 2, "the backoff timer, plus the dropped connection's own health check")

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
        XCTAssertEqual(scheduler.pending.count, 2, "the backoff timer, plus the dropped connection's own health check")

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
        XCTAssertEqual(scheduler.pending.count, 2, "the backoff timer, plus the dropped connection's own health check")

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
        // Confirmed finalized before the second drop: this isolates the
        // OUTAGE buffer's own clearing behaviour (what this test covers)
        // from finding 3's separate "resend what was never finalized"
        // mechanism, which would otherwise legitimately carry this same
        // audio into the next outage precisely because Soniox never
        // confirmed it - see the finding 3 tests below for that case.
        factory.createdSockets[1].simulateResponse(finalAudioProcMs: 4)

        // A second, separate outage.
        factory.createdSockets[1].simulateClosed()
        scheduler.drainOnce()
        factory.createdSockets[2].simulateConfigSent()

        XCTAssertEqual(factory.createdSockets[2].sentAudioChunks.count, 0, "a later, separate outage must not replay the previous outage's already-flushed AND finalized audio")
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
    /// instead of a real `TranslationSession`. Asserts `reportTranslationStarted`
    /// answered `true` (the closure would actually call `translate`) since
    /// every caller of this helper expects a genuine, available request.
    private func drainOneTranslationRequest(
        from session: SonioxLiveSession,
        onStarted: (Int) -> Void = { _ in },
        respond: (Int, String) -> Void
    ) async {
        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        guard let request = await iterator.next() else { return }
        onStarted(request.id)
        XCTAssertTrue(session.reportTranslationStarted(id: request.id), "sanity: this request must be genuinely startable")
        respond(request.id, request.source)
    }

    func test_onlyFinalMeSegmentsAreSentInOrderOneAtATime() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        session.setTranslationAvailable(true)
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
        session.setTranslationAvailable(true)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }

        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        let request = await iterator.next()!
        XCTAssertTrue(session.reportTranslationStarted(id: request.id))
        XCTAssertTrue(lastSegments[0].translationInProgress, "must be on the instant translation actually starts")

        session.reportTranslationSuccess(id: request.id, target: "Hello")
        XCTAssertFalse(lastSegments[0].translationInProgress, "must clear once the result lands")
    }

    func test_successWritesTheWholeTargetOnce() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        session.setTranslationAvailable(true)
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
        session.setTranslationAvailable(true)
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
        session.setTranslationAvailable(true)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }

        do {
            var iterator = session.makeTranslationRequests().makeAsyncIterator()
            let request = await iterator.next()!
            XCTAssertTrue(session.reportTranslationStarted(id: request.id))
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
        session.setTranslationAvailable(true)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }
        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        let staleRequest = await iterator.next()!
        XCTAssertTrue(session.reportTranslationStarted(id: staleRequest.id))

        session.end { }
        scheduler.drainAll()

        // "Phiên mới": a fresh session, fresh SonioxJoinEngine - segment ids
        // restart at 1, colliding numerically with the ended session's own
        // segment 1.
        startAndEstablish(session, factory: factory)
        session.setTranslationAvailable(true)
        factory.createdSockets.last?.simulateResponse(tokens: meSegmentResponseTokens(text: "New session"))

        // The stale request's own (very late) completion arrives.
        session.reportTranslationSuccess(id: staleRequest.id, target: "stale translation")

        XCTAssertNotEqual(lastSegments[0].target, "stale translation", "a stale cross-session report must never corrupt the new session's same-numbered segment")
        XCTAssertNil(lastSegments[0].target)
    }

    // MARK: - Review round 2, finding 1: the availability gate

    /// Nothing is enqueued at all while translation has never been marked
    /// available - not merely started-and-skipped, but never yielded from
    /// the stream in the first place. Proven by enqueuing a genuinely
    /// available segment afterward and checking it is the FIRST thing the
    /// stream ever delivers.
    func test_translationIsNeverEnqueuedWhileUnavailable() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        // `setTranslationAvailable` is never called - fails closed by default.
        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens(text: "Unavailable"))

        XCTAssertFalse(lastSegments[0].translationInProgress)
        XCTAssertFalse(lastSegments[0].targetAbandoned, "never enqueued is not the same as abandoned - just untouched")
        XCTAssertNil(lastSegments[0].target)

        session.setTranslationAvailable(true)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens(text: "Available"))

        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        let received = await iterator.next()!
        XCTAssertEqual(received.source, "Available", "only the segment finalized while available may ever reach the stream")
    }

    /// A direct API-contract check on the second, defensive gate inside
    /// `reportTranslationStarted`: even a request that WAS legitimately
    /// enqueued must not actually start if availability has since dropped.
    func test_reportTranslationStartedReturnsFalseOnceAvailabilityHasDropped() async {
        let (session, factory, _) = makeSession()
        startAndEstablish(session, factory: factory)
        session.setTranslationAvailable(true)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens())

        var iterator = session.makeTranslationRequests().makeAsyncIterator()
        let request = await iterator.next()!
        session.setTranslationAvailable(false)

        XCTAssertFalse(session.reportTranslationStarted(id: request.id), "must not start once availability has dropped, even for an already-queued request")
    }

    // MARK: - Review round 2, finding 2: a stale post-end request must
    // never actually be translated, even though it still surfaces from the
    // shared, long-lived stream (the reviewer's own reproduction: "Old
    // session" came out before "New session").

    func test_endedSessionsQueuedRequestStillSurfacesButMustNeverBeStarted() async {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        session.setTranslationAvailable(true)
        factory.createdSockets[0].simulateResponse(tokens: meSegmentResponseTokens(text: "Old session"))

        var iterator = session.makeTranslationRequests().makeAsyncIterator()

        session.end { }
        scheduler.drainAll()

        startAndEstablish(session, factory: factory)
        session.setTranslationAvailable(true)
        factory.createdSockets.last?.simulateResponse(tokens: meSegmentResponseTokens(text: "New session"))

        let first = await iterator.next()!
        XCTAssertEqual(first.source, "Old session", "the stale request was already sitting in the stream's buffer before end - it still surfaces")
        XCTAssertFalse(session.reportTranslationStarted(id: first.id), "but must never actually start - the consuming closure must skip translate for it entirely")

        let second = await iterator.next()!
        XCTAssertEqual(second.source, "New session")
        XCTAssertTrue(session.reportTranslationStarted(id: second.id), "the new session's own request must proceed normally, right behind the skipped stale one")
    }

    // MARK: - Review round 4, finding 1: at most one open connection, ever -
    // live evidence was every SonioxTranslationStatusShape line duplicated
    // right after a reconnect, proof that two real sockets were briefly
    // both connected and receiving the same audio, with the orphan never
    // closed. The real cause lives partly in the adapter itself
    // (`SonioxStreamSocket.close()`, strengthened to also call the plain
    // `URLSessionTask.cancel()`, since the WebSocket-specific
    // `cancel(with:reason:)` alone is not documented to reliably abort a
    // task still mid-handshake) - fakes cannot reach that, since
    // `FakeSonioxSocketConnection` has no real `URLSessionWebSocketTask` to
    // race against. What fakes CAN prove, and what these tests cover, is
    // the SESSION side: `SonioxLiveSession` must never let more than one
    // socket exist untracked, must always close whatever it creates, and
    // must close every connection it has ever opened when the session ends
    // - regardless of how many reconnects happened first.

    /// The number of sockets currently open (connected, not yet closed)
    /// among everything the factory has ever created.
    private func openSocketCount(_ factory: FakeSonioxSocketFactory) -> Int {
        factory.createdSockets.filter { $0.connectCount > 0 && !$0.isClosed }.count
    }

    func test_atMostOneConnectionIsEverOpenAcrossSeveralConsecutiveReconnects() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        XCTAssertEqual(openSocketCount(factory), 1)

        for _ in 0..<5 {
            factory.createdSockets.last?.simulateClosed()
            XCTAssertLessThanOrEqual(openSocketCount(factory), 1, "no more than one connection may ever be open, even right after a drop")
            scheduler.drainOnce()
            XCTAssertLessThanOrEqual(openSocketCount(factory), 1, "...or right after the retry creates a new socket, before it has even connected")
            factory.createdSockets.last?.simulateConfigSent()
            XCTAssertEqual(openSocketCount(factory), 1, "exactly one connection is open once the reconnect settles")
        }

        XCTAssertEqual(factory.createdSockets.count, 6, "sanity: five reconnects on top of the initial connect")
    }

    func test_endingClosesEveryConnectionCreatedAcrossTheWholeReconnectSequence() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        for _ in 0..<3 {
            factory.createdSockets.last?.simulateClosed()
            scheduler.drainOnce()
            factory.createdSockets.last?.simulateConfigSent()
        }

        var ended = false
        session.end { ended = true }
        scheduler.drainAll()

        XCTAssertTrue(ended)
        XCTAssertTrue(factory.createdSockets.allSatisfy(\.isClosed), "Kết thúc must close EVERY connection this session ever opened, not just the currently-tracked one")
        XCTAssertEqual(openSocketCount(factory), 0)
    }

    /// The exact gap this round found in the session's own bookkeeping: an
    /// INITIAL connect failure (never reaching `.configSent`) must close its
    /// own socket immediately, not leave it open for something else to
    /// eventually get around to.
    func test_initialConnectFailureClosesItsOwnSocketImmediately() {
        let (session, factory, _) = makeSession()
        var started: Bool?
        session.start(config: config) { ok in started = ok }

        factory.createdSockets[0].simulateClosed()

        XCTAssertEqual(started, false)
        XCTAssertTrue(factory.createdSockets[0].isClosed, "an initial connect failure must close its own socket immediately")
    }

    // MARK: - Review round 4, finding 3 (owner decision): resend audio the
    // dropped socket never confirmed finalized, on reconnect, before the
    // outage buffer. Live evidence: in the first mock session, speech
    // Soniox had not yet finalized when the network dropped was lost for
    // good - the open segment kept only its final text, and the audio for
    // the rest had already gone to the now-dead socket.

    /// Byte-level proof: of three one-second chunks sent to the socket that
    /// then drops, only the first is ever reported finalized
    /// (`final_audio_proc_ms`) - so only the other two, still unconfirmed,
    /// may ever reach the reconnecting socket. Resending the first chunk
    /// too would re-recognize speech Soniox already finalized, which is
    /// exactly what would duplicate a segment.
    func test_reconnectResendsOnlyAudioNotYetFinalizedByTheDroppedSocket() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        let chunk1 = Data(repeating: 1, count: 32_000) // 1s at 32,000 bytes/s
        let chunk2 = Data(repeating: 2, count: 32_000)
        let chunk3 = Data(repeating: 3, count: 32_000)
        session.ingestAudio(chunk1)
        session.ingestAudio(chunk2)
        session.ingestAudio(chunk3)

        factory.createdSockets[0].simulateResponse(finalAudioProcMs: 1000) // only chunk1 finalized
        factory.createdSockets[0].simulateClosed()
        scheduler.drainOnce()
        factory.createdSockets[1].simulateConfigSent()

        XCTAssertEqual(factory.createdSockets[1].sentAudioChunks, [chunk2, chunk3], "only audio never confirmed finalized by the dropped socket may be resent")
    }

    /// The end-to-end proof the owner asked for: pre-drop non-final speech
    /// was never shown as a segment (finding 6), so the resend re-recognizing
    /// it after reconnect must land as exactly one segment, never two.
    func test_reconnectResendOfUnfinalizedAudioDoesNotProduceADuplicateSegment() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        var lastSegments: [Segment] = []
        session.onSegmentsChanged = { lastSegments = $0 }

        factory.createdSockets[0].simulateResponse(tokens: [
            SonioxToken(text: "Xin ch", isFinal: false, startMs: nil, endMs: nil, speaker: "1", language: nil, translationStatus: .original),
        ])
        let chunk = Data(repeating: 9, count: 32_000)
        session.ingestAudio(chunk)

        factory.createdSockets[0].simulateClosed()
        XCTAssertTrue(lastSegments.isEmpty, "sanity: the never-finalized segment was never shown, per finding 6 - nothing exists yet to duplicate")
        scheduler.drainOnce()
        factory.createdSockets[1].simulateConfigSent()
        // Review round 5 (B section): exact equality, not just "not empty" -
        // the never-finalized chunk must be resent EXACTLY once, never
        // twice (which would re-recognize it twice) and never skipped.
        XCTAssertEqual(factory.createdSockets[1].sentAudioChunks, [chunk], "the never-finalized audio must be resent exactly once - never twice, never skipped")

        // The new socket re-recognizes the resent audio and finalizes it.
        factory.createdSockets[1].simulateResponse(tokens: [
            SonioxToken(text: "Xin chào", isFinal: true, startMs: 0, endMs: 1000, speaker: "1", language: "vi", translationStatus: .original),
            SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .original),
        ])

        XCTAssertEqual(lastSegments.count, 1, "the resend must land as exactly one segment, never a duplicate")
        XCTAssertEqual(lastSegments[0].source, "Xin chào")
    }

    // MARK: - Review round 4, finding 4a (owner decision): reconnect the
    // instant iOS reports the network path is available again, instead of
    // waiting out backoff - live evidence showed ~30s wasted waiting during
    // the second mock session, all of it spent in backoff after the network
    // had already come back.

    func test_pathAvailableDuringReconnectConnectsImmediatelyWithoutWaitingForBackoff() {
        let (session, factory, scheduler, pathMonitors) = makeSessionWithPathMonitor()
        startAndEstablish(session, factory: factory)
        XCTAssertEqual(pathMonitors.createdMonitors.last?.startCount, 1, "sanity: the monitor starts once the session starts")

        factory.createdSockets[0].simulateClosed()
        XCTAssertEqual(scheduler.pending.count, 2, "sanity: a normal backoff timer is pending, plus the dropped connection's own health check")

        pathMonitors.createdMonitors.last?.simulatePathAvailable()

        XCTAssertEqual(factory.createdSockets.count, 2, "the path becoming available must open a new connection immediately, without waiting for the backoff timer to fire")
    }

    func test_pathAvailablePreemptsThePendingBackoffTimerSoItNeverOpensASecondConnection() {
        let (session, factory, scheduler, pathMonitors) = makeSessionWithPathMonitor()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed()
        pathMonitors.createdMonitors.last?.simulatePathAvailable()
        XCTAssertEqual(factory.createdSockets.count, 2)

        scheduler.drainAll() // the original backoff timer, now stale, fires anyway
        XCTAssertEqual(factory.createdSockets.count, 2, "a backoff timer preempted by the path becoming available must not go on to open a second connection once it eventually fires")
    }

    func test_pathAvailableWhileNotReconnectingIsIgnored() {
        let (session, factory, _, pathMonitors) = makeSessionWithPathMonitor()
        startAndEstablish(session, factory: factory)

        pathMonitors.createdMonitors.last?.simulatePathAvailable()

        XCTAssertEqual(factory.createdSockets.count, 1, "the path becoming available while already connected must not open a redundant new connection")
    }

    func test_endingCancelsThePathMonitor() {
        let (session, factory, scheduler, pathMonitors) = makeSessionWithPathMonitor()
        startAndEstablish(session, factory: factory)

        var ended = false
        session.end { ended = true }
        scheduler.drainAll()

        XCTAssertTrue(ended)
        XCTAssertGreaterThan(pathMonitors.createdMonitors.last?.cancelCount ?? 0, 0, "ending the session must cancel the path monitor too, not just the socket")
    }

    /// Review round 5, finding C6 (blocking): a path event must never abort
    /// an attempt already in flight (a socket created, mid-handshake,
    /// waiting for its own `.configSent` or failure) - only preempt a
    /// genuine "waiting for backoff, nothing in flight yet" gap. The
    /// reviewer's own reproduction: one backoff attempt plus two path
    /// events created four sockets.
    func test_pathAvailableDuringAnInFlightAttemptDoesNotAbortIt() {
        let (session, factory, _, pathMonitors) = makeSessionWithPathMonitor()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed() // drop; backoff scheduled, no socket yet
        pathMonitors.createdMonitors.last?.simulatePathAvailable() // preempts the wait
        XCTAssertEqual(factory.createdSockets.count, 2, "sanity: the first path event opened the replacement socket")

        // A second path event arrives while socket #2 is STILL mid-handshake.
        pathMonitors.createdMonitors.last?.simulatePathAvailable()

        XCTAssertEqual(factory.createdSockets.count, 2, "a path event must never abort an attempt already in flight")
        XCTAssertFalse(factory.createdSockets[1].isClosed, "the in-flight attempt itself must not be aborted")
    }

    // MARK: - Review round 5, finding B1 (blocking): `end()`'s delayed
    // close must only ever close the socket it was scheduled for - never
    // whatever `self.socket` happens to be by the time it fires.

    func test_endsDelayedCloseNeverClosesANewerSessionsSocketStartedDuringTheWait() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        var ended = false
        session.end { ended = true }
        // "Phien moi" starts a brand-new session before the 1.5 s grace
        // window fires.
        var started = false
        session.start(config: config) { ok in started = ok }
        factory.createdSockets[1].simulateConfigSent()
        XCTAssertTrue(started, "sanity: the new session's own socket connected")

        scheduler.drainAll() // the FIRST end()'s delayed close now fires

        XCTAssertTrue(ended)
        XCTAssertTrue(factory.createdSockets[0].isClosed, "the old session's own socket must still be closed")
        XCTAssertFalse(factory.createdSockets[1].isClosed, "a delayed close scheduled by the PREVIOUS session must never reach the NEW session's socket")
    }

    // MARK: - Review round 5, finding B2 (blocking): `final_audio_proc_ms`
    // is cumulative for the whole connection, not a delta since the last
    // response - trimming must track how much has already been consumed.

    func test_trimFinalizedAudioUsesCumulativeFinalAudioProcMsAcrossMultipleResponses() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        let chunk1 = Data(repeating: 1, count: 32_000) // 1s
        let chunk2 = Data(repeating: 2, count: 32_000) // 1s
        session.ingestAudio(chunk1)
        factory.createdSockets[0].simulateResponse(finalAudioProcMs: 500) // 16,000 bytes cumulative
        session.ingestAudio(chunk2)
        factory.createdSockets[0].simulateResponse(finalAudioProcMs: 1000) // 32,000 bytes cumulative total

        factory.createdSockets[0].simulateClosed()
        scheduler.drainOnce()
        factory.createdSockets[1].simulateConfigSent()

        // All of chunk1 (32,000 bytes) is now finalized; only chunk2 is not.
        XCTAssertEqual(factory.createdSockets[1].sentAudioChunks, [chunk2], "cumulative final_audio_proc_ms must not be re-applied as if it were a per-response delta - doing so over-trims and drops audio that was never actually finalized")
    }
}
