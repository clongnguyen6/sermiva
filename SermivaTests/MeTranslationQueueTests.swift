import XCTest
@testable import Sermiva

/// Covers `MeTranslationQueue` directly - the FIFO queue itself, isolated
/// from `SonioxLiveSession`/`SonioxJoinEngine` - for the review round 2
/// finding 3 fix: a superseded stream's belated `onTermination` must never
/// abandon a newer stream's own pending requests.
@MainActor
final class MeTranslationQueueTests: XCTestCase {
    /// Lets every `Task { @MainActor in ... }` hop already scheduled (e.g.
    /// a stream's `onTermination`) actually run before an assertion checks
    /// their effect.
    private func settle(yields: Int = 50) async {
        for _ in 0..<yields {
            await Task.yield()
        }
    }

    /// `iterator.next()`, bounded: a request the bug under test loses
    /// silently (neither delivered nor abandoned) would otherwise hang this
    /// test forever rather than fail it - this turns that into a clean,
    /// fast, red assertion instead.
    private func firstElement(
        _ makeIterator: @escaping () -> AsyncStream<(id: Int, source: String)>.AsyncIterator,
        timeout: Duration = .seconds(2)
    ) async -> (id: Int, source: String)? {
        await withTaskGroup(of: (id: Int, source: String)?.self) { group in
            group.addTask {
                var iterator = makeIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    func test_enqueueBeforeAnyStreamExistsIsReplayedOnceOneIsCreated() async {
        let queue = MeTranslationQueue()
        queue.enqueue(id: 1, source: "early")

        var iterator = queue.makeRequests().makeAsyncIterator()
        let received = await iterator.next()

        XCTAssertEqual(received?.source, "early", "a request enqueued before any stream existed must not be silently lost")
    }

    func test_blankSourceIsNeverEnqueued() async {
        let queue = MeTranslationQueue()
        queue.enqueue(id: 1, source: "   ")
        queue.enqueue(id: 2, source: "real")

        var iterator = queue.makeRequests().makeAsyncIterator()
        let received = await iterator.next()

        XCTAssertEqual(received?.id, 2, "a whitespace-only source must never reach the stream at all")
    }

    /// Review round 2, finding 3's exact reproduction: an old, superseded
    /// stream's `onTermination` must not wipe out a request that by now
    /// belongs to the CURRENT stream, just because it fires late.
    func test_terminationOfASupersededStreamDoesNotAbandonTheCurrentStreamsPendingRequest() async {
        let queue = MeTranslationQueue()
        var abandoned: [Int] = []
        queue.onAbandoned = { abandoned.append($0) }

        do {
            // The old stream - dropped immediately, simulating a
            // `.translationTask` re-run whose original stream is now
            // unreachable but has not yet actually terminated.
            _ = queue.makeRequests()
        }

        let currentStream = queue.makeRequests()
        queue.enqueue(id: 1, source: "Xin chào")

        // Give the old stream's `onTermination` every chance to fire (it
        // hops through a `Task { @MainActor in ... }`) before asserting
        // nothing was abandoned.
        await settle()

        XCTAssertTrue(abandoned.isEmpty, "a superseded stream's own termination must never abandon the current stream's pending request")

        var iterator = currentStream.makeAsyncIterator()
        let received = await iterator.next()
        XCTAssertEqual(received?.id, 1)
        XCTAssertEqual(received?.source, "Xin chào", "the correct, current-stream request must still be the one delivered - never discarded by the stale termination")
    }

    func test_abandonAllDoesNotFinishTheStreamSoALaterEnqueueStillDelivers() async {
        let queue = MeTranslationQueue()
        var abandoned: [Int] = []
        queue.onAbandoned = { abandoned.append($0) }

        let stream = queue.makeRequests()
        queue.enqueue(id: 1, source: "old session")
        queue.abandonAll()

        XCTAssertEqual(abandoned, [1])

        queue.enqueue(id: 2, source: "new session")
        var iterator = stream.makeAsyncIterator()
        // The abandoned id 1 was already sitting in the stream's own
        // buffer before `abandonAll` ran - it still surfaces (this is
        // exactly why `SonioxLiveSession.reportTranslationStarted` returns
        // `Bool`, checked at the consuming end, not here).
        let first = await iterator.next()
        XCTAssertEqual(first?.id, 1)
        let second = await iterator.next()
        XCTAssertEqual(second?.id, 2, "abandonAll must not finish the stream - a later enqueue must still be delivered")
    }

    // MARK: - Review round 3, finding 1: a request enqueued strictly AFTER
    // its stream genuinely terminated (not merely superseded) must be
    // delivered on a later re-run, or abandoned - never silently lost by
    // yielding into a continuation that already died.

    func test_enqueueAfterGenuineTerminationIsDeliveredOnALaterReRun() async {
        let queue = MeTranslationQueue()
        var abandoned: [Int] = []
        queue.onAbandoned = { abandoned.append($0) }

        do {
            _ = queue.makeRequests()
        }
        // Let this stream's own `onTermination` actually run (it is the
        // only stream that ever existed, so this is a genuine termination,
        // not a supersession).
        await settle()

        queue.enqueue(id: 1, source: "after termination")

        let reRunStream = queue.makeRequests()
        let received = await firstElement(reRunStream.makeAsyncIterator)

        XCTAssertEqual(received?.id, 1, "a request enqueued after genuine termination and before a re-run must be delivered on that re-run, never silently lost")
        XCTAssertEqual(received?.source, "after termination")
        XCTAssertTrue(abandoned.isEmpty, "it was delivered, not abandoned")
    }

    func test_enqueueAfterGenuineTerminationIsAbandonedIfNoReRunEverComes() async {
        let queue = MeTranslationQueue()
        var abandoned: [Int] = []
        queue.onAbandoned = { abandoned.append($0) }

        do {
            _ = queue.makeRequests()
        }
        await settle()

        queue.enqueue(id: 1, source: "after termination")
        queue.abandonAll() // e.g. the session ends, with no re-run ever coming

        XCTAssertEqual(abandoned, [1], "a request enqueued after termination, with no re-run, must still be abandonable rather than left pending forever")
    }
}
