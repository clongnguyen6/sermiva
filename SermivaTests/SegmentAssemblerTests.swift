import XCTest
@testable import Sermiva

/// Covers HANDOFF.md section 6's segment assembly rules directly, with
/// hand-built events - no scheduler, no fixture file needed.
final class SegmentAssemblerTests: XCTestCase {
    func test_partialUpdatesInPlaceById() {
        var segments: [Segment] = []
        SegmentAssembler.apply(
            DemoEvent(type: .partial, id: 1, speaker: "A", lang: "vi", src: "Cho tôi", tgt: nil, overlap: nil),
            elapsed: 1,
            to: &segments
        )
        SegmentAssembler.apply(
            DemoEvent(type: .partial, id: 1, speaker: nil, lang: nil, src: "Cho tôi một cà phê", tgt: nil, overlap: nil),
            elapsed: 2,
            to: &segments
        )

        XCTAssertEqual(segments.count, 1, "a partial for an existing id must update in place, not append")
        XCTAssertEqual(segments[0].source, "Cho tôi một cà phê")
        XCTAssertFalse(segments[0].isFinal)
        XCTAssertEqual(segments[0].startedAt, 1, "startedAt is set on creation and does not move on update")
    }

    func test_finalLocksSourceButLeavesTargetForFillTarget() {
        var segments: [Segment] = []
        SegmentAssembler.apply(
            DemoEvent(type: .partial, id: 1, speaker: "A", lang: "vi", src: "Cho tôi", tgt: nil, overlap: nil),
            elapsed: 1,
            to: &segments
        )
        SegmentAssembler.apply(
            DemoEvent(type: .final, id: 1, speaker: nil, lang: nil, src: "Cho tôi một cà phê.", tgt: "I'd like a coffee.", overlap: nil),
            elapsed: 2,
            to: &segments
        )

        XCTAssertTrue(segments[0].isFinal, "final must lock the segment")
        XCTAssertEqual(segments[0].source, "Cho tôi một cà phê.")
        XCTAssertNil(segments[0].target, "target must not appear until fillTarget runs, even though the event carried tgt")

        SegmentAssembler.fillTarget(id: 1, target: "I'd like a coffee.", in: &segments)
        XCTAssertEqual(segments[0].target, "I'd like a coffee.")
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
        var segments: [Segment] = []
        SegmentAssembler.apply(
            DemoEvent(type: .partial, id: 7, speaker: nil, lang: "vi", src: "Cho thêm một ly", tgt: nil, overlap: nil),
            elapsed: 1,
            to: &segments
        )
        SegmentAssembler.apply(
            DemoEvent(type: .final, id: 7, speaker: nil, lang: nil, src: "Cho thêm một ly nước lọc nữa.", tgt: "One more glass of water, please.", overlap: nil),
            elapsed: 2,
            to: &segments
        )

        XCTAssertNil(segments[0].speaker, "a segment with no diarization signal must stay unidentified, never A or B")
    }

    func test_overlapIsStickyFromCreationAndIgnoredOnUpdate() {
        var segments: [Segment] = []
        SegmentAssembler.apply(
            DemoEvent(type: .partial, id: 8, speaker: "B", lang: "en", src: "Sure, for here or", tgt: nil, overlap: true),
            elapsed: 1,
            to: &segments
        )
        SegmentAssembler.apply(
            DemoEvent(type: .partial, id: 8, speaker: nil, lang: nil, src: "Sure, for here or to go?", tgt: nil, overlap: nil),
            elapsed: 2,
            to: &segments
        )

        XCTAssertTrue(segments[0].overlap, "overlap must persist from the event that first signaled it")
    }

    func test_overlapDefaultsFalseWhenNoEventEverSignalsIt() {
        var segments: [Segment] = []
        SegmentAssembler.apply(
            DemoEvent(type: .partial, id: 2, speaker: "B", lang: "en", src: "Would you like", tgt: nil, overlap: nil),
            elapsed: 1,
            to: &segments
        )

        XCTAssertFalse(segments[0].overlap, "'Noi chong' must never show without a real overlap signal")
    }
}
