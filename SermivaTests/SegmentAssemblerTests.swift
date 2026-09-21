import XCTest
@testable import Sermiva

/// Covers HANDOFF.md section 6's segment assembly rules against the real
/// `cafe_vi_en` events from `demo-data.json` - the same fixture the app
/// plays back and `DemoFixtureLoaderTests` reads.
final class SegmentAssemblerTests: XCTestCase {
    private var cafeEvents: [DemoEvent]!

    override func setUpWithError() throws {
        cafeEvents = try DemoFixtureLoader.loadCafeViEnEvents(bundle: Bundle(for: Self.self))
    }

    private func events(forId id: Int) -> [DemoEvent] {
        cafeEvents.filter { $0.id == id }
    }

    func test_partialUpdatesInPlaceById() {
        // Segment 1 in the fixture: two partials, then a final.
        let events = events(forId: 1)
        var segments: [Segment] = []
        SegmentAssembler.apply(events[0], elapsed: 1, to: &segments)
        SegmentAssembler.apply(events[1], elapsed: 2, to: &segments)

        XCTAssertEqual(segments.count, 1, "a partial for an existing id must update in place, not append")
        XCTAssertEqual(segments[0].source, events[1].src)
        XCTAssertFalse(segments[0].isFinal)
        XCTAssertEqual(segments[0].startedAt, 1, "startedAt is set on creation and does not move on update")
    }

    func test_finalLocksSourceButLeavesTargetForFillTarget() throws {
        let events = events(forId: 1)
        let finalEvent = try XCTUnwrap(events.first { $0.type == .final })
        var segments: [Segment] = []
        SegmentAssembler.apply(events[0], elapsed: 1, to: &segments)
        SegmentAssembler.apply(finalEvent, elapsed: 2, to: &segments)

        XCTAssertTrue(segments[0].isFinal, "final must lock the segment")
        XCTAssertEqual(segments[0].source, finalEvent.src)
        XCTAssertNil(segments[0].target, "target must not appear until fillTarget runs, even though the event carried tgt")

        let target = try XCTUnwrap(finalEvent.tgt)
        SegmentAssembler.fillTarget(id: 1, target: target, in: &segments)
        XCTAssertEqual(segments[0].target, target)
    }

    /// `demo-data.json` never sends a stray event after a segment's final -
    /// its events are always well-ordered - so this input has to be built
    /// by hand. It reuses segment 1's real final event's id, changing only
    /// `type` and `src` to stand in for a late partial or a duplicate
    /// delivery arriving after the lock.
    func test_finalLocksSourceAgainstALateOrDuplicateDelivery() throws {
        let events = events(forId: 1)
        let finalEvent = try XCTUnwrap(events.first { $0.type == .final })
        var segments: [Segment] = []
        for event in events {
            SegmentAssembler.apply(event, elapsed: 1, to: &segments)
        }
        XCTAssertTrue(segments[0].isFinal)
        XCTAssertEqual(segments[0].source, finalEvent.src)

        let latePartial = DemoEvent(
            type: .partial,
            id: finalEvent.id,
            speaker: nil,
            lang: nil,
            src: "corrupted source text",
            tgt: nil,
            overlap: nil
        )
        SegmentAssembler.apply(latePartial, elapsed: 2, to: &segments)

        XCTAssertEqual(segments[0].source, finalEvent.src, "a final segment's source must stay locked against any later event")
        XCTAssertTrue(segments[0].isFinal)
    }

    func test_fillTargetDoesNotOverwriteAnExistingTarget() {
        var segments = [Segment(id: 1, speaker: "A", lang: "vi", source: "x", target: "already set", isFinal: true, startedAt: 0, overlap: false)]
        SegmentAssembler.fillTarget(id: 1, target: "replacement", in: &segments)
        XCTAssertEqual(segments[0].target, "already set")
    }

    func test_fillTargetOnMissingIdIsANoOp() {
        var segments: [Segment] = []
        SegmentAssembler.fillTarget(id: 99, target: "x", in: &segments)
        XCTAssertTrue(segments.isEmpty)
    }

    func test_nilSpeakerStaysUnidentifiedAndIsNeverAutoAssigned() {
        // Segment 7 in the fixture has speaker: null in both its events.
        let events = events(forId: 7)
        var segments: [Segment] = []
        for event in events {
            SegmentAssembler.apply(event, elapsed: 1, to: &segments)
        }
        XCTAssertNil(segments[0].speaker, "a segment with no diarization signal must stay unidentified, never A or B")
    }

    func test_overlapIsStickyFromCreationAndIgnoredOnUpdate() {
        // Segment 8 in the fixture: overlap: true on its first partial only.
        let events = events(forId: 8)
        var segments: [Segment] = []
        for event in events {
            SegmentAssembler.apply(event, elapsed: 1, to: &segments)
        }
        XCTAssertTrue(segments[0].overlap, "overlap must persist from the event that first signaled it")
    }

    func test_overlapDefaultsFalseWhenNoEventEverSignalsIt() {
        // Segment 2 in the fixture never carries an overlap field.
        let events = events(forId: 2)
        var segments: [Segment] = []
        for event in events {
            SegmentAssembler.apply(event, elapsed: 1, to: &segments)
        }
        XCTAssertFalse(segments[0].overlap, "'Noi chong' must never show without a real overlap signal")
    }
}
