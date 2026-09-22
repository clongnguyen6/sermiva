import XCTest
@testable import Sermiva

/// Covers `SonioxJoinEngine`'s segment assembly from stream M and, above
/// all, the no-guess join rule from docs/soniox-routing.md: a `me`-language
/// segment's `target` is only ever filled when the certainty test holds,
/// and never guessed - including the exact overlapping-speech scenario the
/// project owner's amendment describes.
@MainActor
final class SonioxJoinEngineTests: XCTestCase {
    private func original(_ text: String, final: Bool, start: Int?, end: Int?, speaker: String? = "1", lang: String?) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: start, endMs: end, speaker: speaker, language: lang, translationStatus: .original)
    }

    private func translation(_ text: String, final: Bool = true) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .translation)
    }

    private func endMarker() -> SonioxToken {
        SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .original)
    }

    // MARK: - M-only segment assembly

    func test_partialThenFinalBuildsSourceAndLocksLanguageOnFirstFinal() {
        let engine = SonioxJoinEngine(meLanguage: "vi")

        engine.applyStreamM([original("Xin", final: false, start: 0, end: 400, lang: nil)])
        XCTAssertEqual(engine.segments.count, 1)
        XCTAssertEqual(engine.segments[0].source, "Xin")
        XCTAssertNil(engine.segments[0].lang, "language must stay nil until the first final token")
        XCTAssertFalse(engine.segments[0].isFinal)

        engine.applyStreamM([original(" chào", final: true, start: 0, end: 1000, lang: "vi")])
        XCTAssertEqual(engine.segments[0].lang, "vi")
        XCTAssertEqual(engine.segments[0].speaker, "A", "speaker \"1\" must map to label A")
    }

    func test_endMarkerClosesTheOpenSegment() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Chào", final: true, start: 0, end: 500, lang: "vi")])
        XCTAssertFalse(engine.segments[0].isFinal)

        engine.applyStreamM([endMarker()])
        XCTAssertTrue(engine.segments[0].isFinal)
    }

    func test_speakerChangeWithoutEndMarkerCutsANewSegment() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi")])
        XCTAssertEqual(engine.segments.count, 1)

        engine.applyStreamM([original("Hi", final: true, start: 600, end: 900, speaker: "2", lang: "en")])

        XCTAssertEqual(engine.segments.count, 2, "a final token from a different speaker must start a new segment even with no <end>")
        XCTAssertTrue(engine.segments[0].isFinal, "the previous segment must be locked closed")
        XCTAssertEqual(engine.segments[0].speaker, "A")
        XCTAssertEqual(engine.segments[1].speaker, "B")
    }

    func test_mTranslationFillsTargetOnlyForNonMeLanguage() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            translation("Chào"),
            endMarker(),
        ])
        XCTAssertEqual(engine.segments[0].target, "Chào", "a non-me segment's translation comes straight from M")
    }

    func test_mTranslationIsDiscardedForAMeLanguageSegment() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            translation("Chào"), // same-language echo from the one_way(me) config
            endMarker(),
        ])
        XCTAssertNil(engine.segments[0].target, "M's own same-language translation must never land on a me-language segment - only T, via the join, may")
    }

    // MARK: - No-guess join: clean case

    func test_cleanJoinFillsTargetFromStreamT() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        XCTAssertNil(engine.segments[0].target)

        engine.applyStreamT(
            [
                original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
                translation("Hello"),
            ],
            finalAudioProcMs: 1200
        )

        XCTAssertEqual(engine.segments[0].target, "Hello")
        XCTAssertFalse(engine.segments[0].targetAbandoned)
    }

    func test_translatingPlaceholderStaysUpUntilTPassesTheWindow() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertTrue(display.showsTranslatingPlaceholder, "final with no target yet, and not abandoned, must still show the placeholder")
    }

    // MARK: - No-guess join: the owner's overlapping-speech scenario

    /// The exact case owner amendment 1 describes: in the same time window
    /// the owner (me) and the guest both speak. T also translates the
    /// guest, whose original tokens land in `target`'s own language inside
    /// the window. A bare start_ms join would wrongly attach the guest's
    /// translation to the owner's line; the certainty test must instead
    /// leave `target` empty and mark the join abandoned.
    func test_overlappingGuestSpeechInTheWindowAbandonsTheJoinRatherThanGuessing() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        engine.applyStreamT(
            [
                original("Xin chào", final: true, start: 0, end: 400, speaker: "1", lang: "vi"),
                original("hi there", final: true, start: 450, end: 900, speaker: "2", lang: "en"), // the guest, overlapping
                translation("hi there in target"), // belongs to the guest's chunk, not the owner's
            ],
            finalAudioProcMs: 1200
        )

        XCTAssertNil(engine.segments[0].target, "must never attach the guest's translation to the owner's line")
        XCTAssertTrue(engine.segments[0].targetAbandoned, "the join must be recorded as abandoned, not merely still pending")

        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "an abandoned join must never keep showing Đang dịch…")
    }

    func test_mSeeingItsOwnOverlapDisqualifiesTheJoinEvenIfTNeverSawAWrongLanguageToken() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
            // A second speaker's token lands inside segment 1's own window -
            // M itself detected overlap, independent of anything T sees.
            original("hi", final: true, start: 500, end: 700, speaker: "2", lang: "en"),
        ])

        engine.applyStreamT(
            [
                original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
                translation("Hello"),
            ],
            finalAudioProcMs: 1200
        )

        XCTAssertNil(engine.segments[0].target, "M's own detected overlap must disqualify the join, per check 2")
        XCTAssertTrue(engine.segments[0].targetAbandoned)
    }

    func test_noTranslationArrivesAtAllLeavesTargetNilNotStuckForever() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        engine.applyStreamT([], finalAudioProcMs: 1200)

        XCTAssertNil(engine.segments[0].target)
        XCTAssertTrue(engine.segments[0].targetAbandoned, "once T has passed the window with nothing collected, the placeholder must stop, not hang")
    }

    // MARK: - Speaker label mapping

    func test_speakerLabelMapsNumericStringsInOrder() {
        XCTAssertEqual(SonioxSpeakerLabel.label(for: "1"), "A")
        XCTAssertEqual(SonioxSpeakerLabel.label(for: "2"), "B")
        XCTAssertEqual(SonioxSpeakerLabel.label(for: "3"), "C")
        XCTAssertNil(SonioxSpeakerLabel.label(for: nil), "missing speaker must stay nil, never guessed")
        XCTAssertNil(SonioxSpeakerLabel.label(for: "not-a-number"))
    }
}
