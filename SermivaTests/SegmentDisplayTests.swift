import XCTest
@testable import Sermiva

/// `SegmentDisplay.make` is the single place that decides whether an
/// activity indicator shows for a segment - the recognizing tag and its
/// dot, the caret, the "Dang dich..." placeholder, the VoiceOver trait, and
/// the language label. `CaptionsTranscriptView` only reads the result, so
/// this is where every state demo actually passes through must be covered.
final class SegmentDisplayTests: XCTestCase {
    private func segment(
        lang: String? = "vi",
        isFinal: Bool,
        target: String? = nil
    ) -> Segment {
        Segment(id: 1, speaker: "A", lang: lang, source: "x", target: target, isFinal: isFinal, startedAt: 0, overlap: false)
    }

    func test_partialSegmentWhileRunningShowsRecognizingTagCaretAndUpdatesFrequently() {
        let display = SegmentDisplay.make(for: segment(isFinal: false), isActivityRunning: true)
        XCTAssertTrue(display.showsRecognizingTag)
        XCTAssertTrue(display.showsCaret)
        XCTAssertTrue(display.updatesFrequently)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "a partial has no target yet to translate")
    }

    func test_partialSegmentWhileNotRunningHidesEveryIndicator() {
        let display = SegmentDisplay.make(for: segment(isFinal: false), isActivityRunning: false)
        XCTAssertFalse(display.showsRecognizingTag)
        XCTAssertFalse(display.showsCaret)
        XCTAssertFalse(display.updatesFrequently)
        XCTAssertFalse(display.showsTranslatingPlaceholder)
    }

    func test_finalSegmentAwaitingTranslationWhileRunningShowsThePlaceholderOnly() {
        let display = SegmentDisplay.make(for: segment(isFinal: true, target: nil), isActivityRunning: true)
        XCTAssertTrue(display.showsTranslatingPlaceholder)
        XCTAssertFalse(display.showsRecognizingTag)
        XCTAssertFalse(display.showsCaret)
        XCTAssertFalse(display.updatesFrequently, "a final segment is never mid-recognition any more")
    }

    func test_finalSegmentAwaitingTranslationWhileNotRunningShowsNoPlaceholder() {
        let display = SegmentDisplay.make(for: segment(isFinal: true, target: nil), isActivityRunning: false)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "paused or ended must not claim a translation is in progress")
    }

    func test_finalSegmentWithATargetShowsNoIndicatorRegardlessOfRunning() {
        for running in [true, false] {
            let display = SegmentDisplay.make(for: segment(isFinal: true, target: "done"), isActivityRunning: running)
            XCTAssertFalse(display.showsRecognizingTag, "running=\(running)")
            XCTAssertFalse(display.showsCaret, "running=\(running)")
            XCTAssertFalse(display.showsTranslatingPlaceholder, "a landed translation is a fact, not an activity, running=\(running)")
            XCTAssertFalse(display.updatesFrequently, "running=\(running)")
        }
    }

    // MARK: - L3: the "recognizing language" fallback is an activity claim
    // too - `nil` means show nothing at that position, not fallback text.

    func test_knownLanguageAlwaysShowsRegardlessOfRunning() {
        for running in [true, false] {
            let display = SegmentDisplay.make(for: segment(lang: "vi", isFinal: false), isActivityRunning: running)
            XCTAssertEqual(display.languageText, "Tiếng Việt", "running=\(running)")
        }
    }

    func test_unknownLanguageWhileRunningShowsTheRecognizingLabel() {
        let display = SegmentDisplay.make(for: segment(lang: nil, isFinal: false), isActivityRunning: true)
        XCTAssertEqual(display.languageText, "Đang nhận diện ngôn ngữ")
    }

    func test_unknownLanguageWhileNotRunningShowsNothing() {
        let display = SegmentDisplay.make(for: segment(lang: nil, isFinal: false), isActivityRunning: false)
        XCTAssertNil(display.languageText, "paused or ended must not claim language recognition is in progress")
    }
}
