import XCTest
@testable import Sermiva

/// Covers `SonioxLiveSession`'s reconnect/retry policy - pair generation,
/// stale-event filtering, the single retry timer, backoff, the audio
/// buffer, auth precedence, and socket ownership/teardown. This is
/// app-owned logic, not Soniox's wire shape: everything here goes through
/// `SonioxSocketConnecting`'s `FakeSonioxSocketConnection`, never through
/// `SonioxStreamSocket`, no Soniox JSON, no fixtures of the wire format -
/// the boundary AGENTS.md requires. `ManualScheduler` replaces real time,
/// so every test runs instantly and deterministically.
@MainActor
final class SonioxLiveSessionTests: XCTestCase {
    private let config = SonioxSessionConfig(apiKey: "sx_test_key_not_real", meLanguage: "vi", targetLanguage: "en", guestHint: nil)

    private func makeSession() -> (session: SonioxLiveSession, factory: FakeSonioxSocketFactory, scheduler: ManualScheduler) {
        let factory = FakeSonioxSocketFactory()
        let scheduler = ManualScheduler()
        let session = SonioxLiveSession(makeSocket: factory.make, scheduler: scheduler)
        return (session, factory, scheduler)
    }

    /// Starts the session and completes the initial handshake (both
    /// sockets report their config sent) - the common starting point most
    /// tests below build on.
    @discardableResult
    private func startAndEstablish(_ session: SonioxLiveSession, factory: FakeSonioxSocketFactory) -> Bool {
        var started = false
        session.start(config: config) { ok in started = ok }
        // The pair THIS call just created - not necessarily indices 0/1,
        // since a session object can be reused for a later "Phien moi".
        let pair = factory.createdSockets.suffix(2)
        pair.first?.simulateConfigSent()
        pair.last?.simulateConfigSent()
        return started
    }

    func test_startSucceedsOnceBothSocketsReportConfigSent() {
        let (session, factory, _) = makeSession()
        let ok = startAndEstablish(session, factory: factory)

        XCTAssertTrue(ok)
        XCTAssertEqual(factory.createdSockets.count, 2)
    }

    // MARK: - Finding 1: overlapping retries

    /// The exact bug: after M closes, T's own close event for the SAME
    /// pair must not schedule a second, overlapping retry timer.
    func test_doubleCloseFromOnePairSchedulesExactlyOneRetry() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed() // M drops
        factory.createdSockets[1].simulateClosed() // T's own close for the same pair, moments later

        XCTAssertEqual(scheduler.pending.count, 1, "a double close from the same pair must schedule exactly one retry, not two")

        scheduler.drainOnce()
        XCTAssertEqual(factory.createdSockets.count, 4, "exactly one replacement pair must be created")
        XCTAssertTrue(factory.createdSockets[0].isClosed)
        XCTAssertTrue(factory.createdSockets[1].isClosed, "every socket the session ever opens must be closed by the session")
    }

    /// A stale event from a pair already superseded by a LATER retry - not
    /// just the immediate double-close case above - must also be ignored.
    func test_staleEventFromAnAlreadySupersededPairIsIgnored() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed()
        scheduler.drainOnce() // retry fires, pair 2 created (indices 2, 3)
        XCTAssertEqual(factory.createdSockets.count, 4)

        // A very late event from pair 1 (already superseded) arrives.
        factory.createdSockets[1].simulateClosed()

        XCTAssertEqual(scheduler.pending.count, 0, "a stale event from an already-superseded pair must not schedule anything")
    }

    /// A replacement pair itself failing before it ever connects must
    /// retry again, not get stuck.
    func test_replacementPairFailingBeforeConnectingRetriesAgain() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed()
        scheduler.drainOnce() // pair 2 created (indices 2, 3), not yet connected
        XCTAssertEqual(factory.createdSockets.count, 4)

        factory.createdSockets[2].simulateClosed() // pair 2's own M fails too

        XCTAssertEqual(scheduler.pending.count, 1, "a failed replacement pair must schedule exactly one more retry")
        scheduler.drainOnce()
        XCTAssertEqual(factory.createdSockets.count, 6, "a third pair must be opened")
        XCTAssertTrue(factory.createdSockets[2].isClosed)
        XCTAssertTrue(factory.createdSockets[3].isClosed)
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
        XCTAssertEqual(factory.createdSockets.count, 2, "a retry pending when the session ends must never open a new pair")
    }

    func test_pauseDuringBackoffDoesNotInterfereWithThePendingRetry() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateClosed()
        XCTAssertEqual(scheduler.pending.count, 1)

        session.beginPauseKeepalive() // must not crash even with no socket open
        session.endPauseKeepalive()

        scheduler.drainOnce()
        XCTAssertEqual(factory.createdSockets.count, 4, "pausing mid-backoff must not cancel or duplicate the pending retry")
    }

    /// An auth rejection wins at any point, including from a socket this
    /// class has already superseded - and, once the consumer reacts to it
    /// the same way `LiveSessionController` does (ending the session
    /// immediately), a pending retry must never go on to open a new pair.
    func test_authRejectedDuringBackoffWinsAndStopsThePendingRetry() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)
        factory.createdSockets[0].simulateClosed()
        XCTAssertEqual(scheduler.pending.count, 1)

        session.onAuthError = { [weak session] in
            session?.endImmediately { }
        }
        factory.createdSockets[1].simulateAuthRejected() // from the already-superseded pair

        scheduler.drainAll()
        XCTAssertEqual(factory.createdSockets.count, 2, "an auth rejection must stop the pending retry from ever opening a new pair")
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
        startAndEstablish(session, factory: factory) // session 1: sockets 0, 1

        var ended = false
        session.end { ended = true }
        scheduler.drainAll()
        XCTAssertTrue(ended)

        var authErrorCount = 0
        session.onAuthError = { authErrorCount += 1 }
        startAndEstablish(session, factory: factory) // session 2 (Phien moi): sockets 2, 3

        // A very late straggler from session 1's original socket arrives.
        factory.createdSockets[0].simulateAuthRejected()

        XCTAssertEqual(authErrorCount, 0, "a stale auth event from a previous, already-ended session must not leak into a new one")
    }

    // MARK: - Finding 2: the audio buffer across a multi-attempt outage

    /// Audio captured across a WHOLE outage - including during a failed
    /// attempt in the middle of it - must all reach the pair that finally
    /// succeeds, not be discarded by any attempt that failed along the way.
    func test_bufferedAudioPersistsAcrossFailedRetryAttemptsWithinOneOutage() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed() // outage begins
        session.ingestAudio(Data(repeating: 1, count: 100))
        scheduler.drainOnce() // retry 1 fires, pair 2 created (indices 2, 3), not yet connected
        session.ingestAudio(Data(repeating: 2, count: 100))

        factory.createdSockets[2].simulateClosed() // pair 2 also fails before connecting
        scheduler.drainOnce() // retry 2 fires, pair 3 created (indices 4, 5)

        factory.createdSockets[4].simulateConfigSent()
        factory.createdSockets[5].simulateConfigSent()

        XCTAssertEqual(factory.createdSockets[4].sentAudioChunks.count, 2, "audio captured across the whole outage must not be discarded by a failed attempt in between")
        XCTAssertEqual(factory.createdSockets[5].sentAudioChunks.count, 2)
    }

    /// Once actually flushed to a pair that connected, the buffer is
    /// empty again - a LATER, separate outage starts from nothing, not
    /// from whatever the previous outage happened to buffer.
    func test_bufferedAudioClearsOnceFlushedAndDoesNotCarryIntoALaterSeparateOutage() {
        let (session, factory, scheduler) = makeSession()
        startAndEstablish(session, factory: factory)

        factory.createdSockets[0].simulateClosed()
        session.ingestAudio(Data(repeating: 1, count: 100))
        scheduler.drainOnce()
        factory.createdSockets[2].simulateConfigSent()
        factory.createdSockets[3].simulateConfigSent()
        XCTAssertEqual(factory.createdSockets[2].sentAudioChunks.count, 1)

        // A second, separate outage.
        factory.createdSockets[2].simulateClosed()
        scheduler.drainOnce()
        factory.createdSockets[4].simulateConfigSent()
        factory.createdSockets[5].simulateConfigSent()

        XCTAssertEqual(factory.createdSockets[4].sentAudioChunks.count, 0, "a later, separate outage must not replay the previous outage's already-flushed audio")
    }

    /// Re-review finding 3: ending mid-outage is the obvious choice for
    /// what buffered-but-never-sent audio means - it stops meaning
    /// anything once the session it was captured for is over. Buffers
    /// audio BEFORE the new session's pair reports ready, so the new
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
        // arrives before its pair has connected, so it goes through the
        // buffer too.
        var started = false
        session.start(config: config) { ok in started = ok }
        session.ingestAudio(Data(repeating: 2, count: 100))
        let pair = factory.createdSockets.suffix(2)
        pair.first?.simulateConfigSent()
        pair.last?.simulateConfigSent()
        XCTAssertTrue(started)

        XCTAssertEqual(factory.createdSockets[2].sentAudioChunks.count, 1, "only the new session's own buffered audio may be flushed, never the previous ended session's leftover buffer")
    }
}
