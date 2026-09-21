import XCTest
@testable import Sermiva

/// Sanity check that the loader reads the real `demo-data.json` fixture
/// (bundled from `design/claude-handoff/`, not a copy) rather than a stub.
final class DemoFixtureLoaderTests: XCTestCase {
    func test_loadsAllSixteenCafeEventsFromTheRealFixture() throws {
        let events = try DemoFixtureLoader.loadCafeViEnEvents(bundle: Bundle(for: Self.self))

        XCTAssertEqual(events.count, 36, "cafe_vi_en has 36 partial/final events across its 16 segments")
        XCTAssertEqual(events.first?.id, 1)
        XCTAssertEqual(events.last?.id, 16)

        let unidentified = events.first { $0.id == 7 }
        XCTAssertEqual(unidentified?.speaker, nil, "segment 7 has no speaker in the fixture")

        let overlapping = events.first { $0.id == 8 && $0.overlap == true }
        XCTAssertNotNil(overlapping, "segment 8's first partial carries the overlap signal in the fixture")
    }

    func test_replayingTheRealFixtureThroughTheAssemblerEndsWithSixteenCompleteSegments() throws {
        let events = try DemoFixtureLoader.loadCafeViEnEvents(bundle: Bundle(for: Self.self))

        var segments: [Segment] = []
        for (index, event) in events.enumerated() {
            SegmentAssembler.apply(event, elapsed: TimeInterval(index), to: &segments)
            if event.type == .final, let tgt = event.tgt {
                SegmentAssembler.fillTarget(id: event.id, target: tgt, in: &segments)
            }
        }

        XCTAssertEqual(segments.count, 16)
        XCTAssertTrue(segments.allSatisfy(\.isFinal))
        XCTAssertTrue(segments.allSatisfy { $0.target != nil })

        let seg7 = try XCTUnwrap(segments.first { $0.id == 7 })
        XCTAssertNil(seg7.speaker, "unidentified speaker must survive a full fixture replay")

        let seg8 = try XCTUnwrap(segments.first { $0.id == 8 })
        let seg9 = try XCTUnwrap(segments.first { $0.id == 9 })
        XCTAssertTrue(seg8.overlap)
        XCTAssertTrue(seg9.overlap)

        let seg1 = try XCTUnwrap(segments.first { $0.id == 1 })
        XCTAssertEqual(seg1.source, "Cho tôi một cà phê sữa đá, ít đường nhé.")
        XCTAssertEqual(seg1.target, "I'd like an iced Vietnamese coffee with less sugar, please.")
    }
}
