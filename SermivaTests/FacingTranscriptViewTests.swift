import XCTest
@testable import Sermiva

/// `FacingPaneContent.make` is the single place that decides what each
/// "Đối diện" reading region shows for the one latest segment - including
/// the two cases where nothing usable exists and the rule (AGENTS.md, and
/// this outcome's own constraint) is to show only what is real, never an
/// invented or mislabeled translation.
final class FacingTranscriptViewTests: XCTestCase {
    private func segment(
        speaker: String? = "A",
        lang: String?,
        source: String = "src",
        target: String? = nil,
        isFinal: Bool = true,
        translationInProgress: Bool = false,
        targetAbandoned: Bool = false
    ) -> Segment {
        Segment(id: 1, speaker: speaker, lang: lang, source: source, target: target, isFinal: isFinal, startedAt: 0, overlap: false, targetAbandoned: targetAbandoned, translationInProgress: translationInProgress)
    }

    private func display(_ segment: Segment, isActivityRunning: Bool = true) -> SegmentDisplay {
        SegmentDisplay.make(for: segment, isActivityRunning: isActivityRunning)
    }

    func test_noSegmentYetShowsOnlyTheReaderLabel() {
        let content = FacingPaneContent.make(readerLanguage: "vi", me: "vi", target: "en", latest: nil)
        XCTAssertEqual(content.readerLabel, "Đọc tiếng Việt")
        XCTAssertFalse(content.hasSegment)
        XCTAssertNil(content.big)
        XCTAssertNil(content.small)
        XCTAssertFalse(content.isTranslatingBig)
    }

    /// The reader's own language: the original is the big line, at full
    /// size, with no translation needed to read it.
    func test_sameLanguageAsReaderShowsSourceBigAndAnyExistingTargetSmall() {
        let display = display(segment(lang: "vi", source: "Xin chào", target: "Hello"))
        let content = FacingPaneContent.make(readerLanguage: "vi", me: "vi", target: "en", latest: display)
        XCTAssertEqual(content.big, "Xin chào")
        XCTAssertEqual(content.small, "Hello")
        XCTAssertFalse(content.isTranslatingBig)
    }

    /// A `me`-language segment's translation is guaranteed to land in
    /// `target` (docs/soniox-routing.md) - the target reader's big line.
    func test_meSegmentShowsItsTargetTranslationBigToTheTargetReader() {
        let display = display(segment(lang: "vi", source: "Xin chào", target: "Hello"))
        let content = FacingPaneContent.make(readerLanguage: "en", me: "vi", target: "en", latest: display)
        XCTAssertEqual(content.big, "Hello")
        XCTAssertEqual(content.small, "Xin chào")
    }

    /// Same case, before the translation has arrived: the genuinely-running
    /// signal (`translationInProgress`) is what gates the spinner - never
    /// merely `target == nil`, per AGENTS.md's activity-indicator invariant.
    func test_meSegmentAwaitingTranslationShowsSpinnerNotInventedTextToTheTargetReader() {
        let display = display(segment(lang: "vi", source: "Xin chào", target: nil, translationInProgress: true))
        let content = FacingPaneContent.make(readerLanguage: "en", me: "vi", target: "en", latest: display)
        XCTAssertNil(content.big, "no target text exists yet - nothing must be invented to fill it")
        XCTAssertTrue(content.isTranslatingBig)
    }

    /// A guest segment's translation is guaranteed to land in `me`
    /// (docs/soniox-routing.md), regardless of what language the guest
    /// actually spoke.
    func test_guestSegmentInTargetLanguageShowsItsMeTranslationBigToTheMeReader() {
        let display = display(segment(lang: "en", source: "Hello", target: "Xin chào"))
        let content = FacingPaneContent.make(readerLanguage: "vi", me: "vi", target: "en", latest: display)
        XCTAssertEqual(content.big, "Xin chào")
        XCTAssertEqual(content.small, "Hello")
    }

    /// The guest speaking a third language that is neither `me` nor
    /// `target`: no translation into the target reader's language has ever
    /// been requested, and the one `target` field that exists is in `me`'s
    /// language - showing it here would silently mislabel it as English.
    /// Per AGENTS.md, show the real source instead, and nothing invented as
    /// the supplementary line.
    func test_guestSpeaksAThirdLanguageShowsRawSourceToTheTargetReaderNeverTheMeTranslation() {
        let display = display(segment(lang: "ja", source: "こんにちは", target: "Xin chào"))
        let content = FacingPaneContent.make(readerLanguage: "en", me: "vi", target: "en", latest: display)
        XCTAssertEqual(content.big, "こんにちは", "the real content, not the vi-language translation mislabeled as English")
        XCTAssertNil(content.small, "the only other field that exists (the vi translation) is in neither reader's language")
        XCTAssertFalse(content.isTranslatingBig, "no translation into English is ever requested for this segment - showing a spinner would claim activity that will never run")
    }

    /// The me reader is unaffected by a third-language guest segment: per
    /// the fixed routing, every non-`me` segment's translation always lands
    /// in `me`, regardless of its actual source language.
    func test_guestSpeaksAThirdLanguageStillShowsTheMeTranslationBigToTheMeReader() {
        let display = display(segment(lang: "ja", source: "こんにちは", target: "Xin chào"))
        let content = FacingPaneContent.make(readerLanguage: "vi", me: "vi", target: "en", latest: display)
        XCTAssertEqual(content.big, "Xin chào")
        XCTAssertEqual(content.small, "こんにちは")
    }

    /// Language not yet identified: neither reader can be told which
    /// direction a translation would even go, so both fall back to the raw
    /// (possibly still-partial) source text, with no supplementary line.
    func test_unidentifiedLanguageShowsRawSourceToBothReaders() {
        let display = display(segment(lang: nil, source: "..."), isActivityRunning: true)
        let meSide = FacingPaneContent.make(readerLanguage: "vi", me: "vi", target: "en", latest: display)
        let targetSide = FacingPaneContent.make(readerLanguage: "en", me: "vi", target: "en", latest: display)
        XCTAssertEqual(meSide.big, "...")
        XCTAssertEqual(targetSide.big, "...")
        XCTAssertNil(meSide.small)
        XCTAssertNil(targetSide.small)
    }

    /// A `me` segment whose on-device translation is permanently unavailable
    /// (`targetAbandoned`): per docs/display-style-picker.md's ruling, the
    /// target reader's big line falls back to the segment's own real,
    /// untranslated source text rather than staying blank - never an
    /// invented translation, and no spinner (nothing is genuinely running).
    func test_meSegmentWithAbandonedTranslationShowsSourceTextNotBlankToTheTargetReader() {
        let display = display(segment(lang: "vi", source: "Xin chào", target: nil, translationInProgress: false, targetAbandoned: true))
        let content = FacingPaneContent.make(readerLanguage: "en", me: "vi", target: "en", latest: display)
        XCTAssertEqual(content.big, "Xin chào", "no target text will ever arrive for this segment - the real source text must show instead of leaving the big line blank")
        XCTAssertNil(content.small, "the only other field that exists (the abandoned target, which is nil) is already the big line here")
        XCTAssertFalse(content.isTranslatingBig, "translation has been given up on for this segment - it is not genuinely running")
    }

    /// `isPartial` drives the "Đang nhận dạng" tag `FacingPane` renders next
    /// to the reader label - it must track the segment's own
    /// `showsRecognizingTag` (a still-running partial), not a constant, in
    /// both directions: true while genuinely partial, false again once the
    /// segment goes final.
    func test_isPartialTracksTheSegmentsOwnRecognizingTagInBothDirections() {
        let partialDisplay = display(segment(lang: "vi", source: "Xin", isFinal: false))
        let partialContent = FacingPaneContent.make(readerLanguage: "vi", me: "vi", target: "en", latest: partialDisplay)
        XCTAssertTrue(partialContent.isPartial, "a still-running partial must show the recognizing tag")

        let finalDisplay = display(segment(lang: "vi", source: "Xin chào", isFinal: true))
        let finalContent = FacingPaneContent.make(readerLanguage: "vi", me: "vi", target: "en", latest: finalDisplay)
        XCTAssertFalse(finalContent.isPartial, "a final segment must not keep showing the recognizing tag")
    }

    func test_readerLabelForAThirdLanguageUsesTheExistingLanguageNameFallback() {
        let content = FacingPaneContent.make(readerLanguage: "ja", me: "vi", target: "en", latest: nil)
        XCTAssertEqual(content.readerLabel, "Đọc JA", "no Japanese entry in LanguageNames yet, so it must fall back to the existing uppercase-code rule, not invent a new label")
    }
}
