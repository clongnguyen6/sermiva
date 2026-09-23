import XCTest
@testable import Sermiva

/// Covers `SonioxJoinEngine`'s segment assembly from stream M - the sole
/// source of segments, speakers, boundaries, and M-direct (non-`me`)
/// translation - plus the small on-device translation lifecycle surface
/// (`onMeSegmentFinalized`, `applyTranslation...`) that replaced the old
/// two-stream no-guess join per docs/soniox-routing.md (option C). The
/// former second Soniox stream, its join, and its `SonioxToken`-level
/// certainty tests no longer exist - see git history (pre-option-C) for
/// that coverage.
@MainActor
final class SonioxJoinEngineTests: XCTestCase {
    private func original(_ text: String, final: Bool, start: Int?, end: Int?, speaker: String? = "1", lang: String?) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: start, endMs: end, speaker: speaker, language: lang, translationStatus: .original)
    }

    private func translation(_ text: String, final: Bool = true) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .translation)
    }

    /// Live-confirmed: markers are not reliably tagged `.original` - a
    /// `status` parameter lets a test send `<end>`/`<fin>` under any of the
    /// four `TranslationStatus` cases and check it still closes regardless.
    private func endMarker(status: SonioxToken.TranslationStatus = .original) -> SonioxToken {
        SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: status)
    }

    /// Live-confirmed: original (spoken) text this stream is not
    /// translating, because it is already in this stream's own target
    /// language - see docs/soniox-routing.md's Unknowns table.
    private func noneStatus(_ text: String, final: Bool, start: Int?, end: Int?, speaker: String? = "1", lang: String?) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: start, endMs: end, speaker: speaker, language: lang, translationStatus: .none)
    }

    /// A wire value that is neither of the three documented strings - must
    /// never be silently folded into `.none`, which now carries real
    /// meaning.
    private func unrecognizedStatus(_ text: String, final: Bool = true, start: Int? = 0, end: Int? = 500) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: start, endMs: end, speaker: "1", language: "vi", translationStatus: .unrecognized)
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

    /// Issue 1: non-final tokens are replaced in full on every response
    /// (docs/soniox-routing.md), never appended to the previous tail. A
    /// naive `+=` here would turn "Xin" then "Xin chào" into "XinXin chào".
    func test_nonFinalTokensReplaceThePreviousTailRatherThanAppending() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Xin", final: false, start: 0, end: 400, lang: nil)])
        XCTAssertEqual(engine.segments[0].source, "Xin")

        engine.applyStreamM([original("Xin chào", final: false, start: 0, end: 900, lang: nil)])

        XCTAssertEqual(engine.segments[0].source, "Xin chào", "a new response's non-final tokens must replace the previous tail, not append to it")
    }

    /// A response with no non-final tail at all (everything finalized) must
    /// clear any stale partial text rather than leave it appended forever.
    func test_finalTokenClearsAnyPreviousNonFinalTail() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Xin", final: false, start: 0, end: 400, lang: nil)])
        XCTAssertEqual(engine.segments[0].source, "Xin")

        engine.applyStreamM([original("Xin chào", final: true, start: 0, end: 900, lang: "vi")])

        XCTAssertEqual(engine.segments[0].source, "Xin chào", "the response's own final text must be exactly what shows, not final text plus a stale tail")
    }

    func test_endMarkerClosesTheOpenSegment() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Chào", final: true, start: 0, end: 500, lang: "en")])
        XCTAssertFalse(engine.segments[0].isFinal)

        engine.applyStreamM([endMarker()])
        XCTAssertTrue(engine.segments[0].isFinal)
    }

    func test_speakerChangeWithoutEndMarkerCutsANewSegment() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi")])
        XCTAssertEqual(engine.segments.count, 1)

        engine.applyStreamM([original(" Hi", final: true, start: 600, end: 900, speaker: "2", lang: "en")])

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
        XCTAssertNil(engine.segments[0].target, "M's own same-language translation must never land on a me-language segment - only on-device translation may")
    }

    /// Issue 3c: a non-me segment M never sends a translation for must stop
    /// claiming one is coming, once M has moved on to the next segment -
    /// not hang on "Đang dịch…" for the rest of the session.
    func test_nonMeSegmentWithNoMTranslationIsAbandonedOnceMMovesOn() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            endMarker(),
            // No translation token ever arrives for segment 1 - M just
            // moves on to a new segment.
            original("More", final: true, start: 600, end: 900, speaker: "1", lang: "en"),
        ])

        XCTAssertNil(engine.segments[0].target)
        XCTAssertTrue(engine.segments[0].targetAbandoned, "M moving on without ever sending a translation must stop the placeholder")
        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder)
    }

    /// The M-direct (non-`me`) placeholder rule: nothing shows before M has
    /// sent any translation token for this segment.
    func test_nonMePlaceholderDoesNotShowBeforeAnyMTranslationTokenArrives() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            endMarker(),
        ])
        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder)
    }

    /// ...and shows once a real (even non-final) M translation token
    /// arrives, without that partial text ever landing in `target`.
    func test_nonMePlaceholderShowsOnceANonFinalMTranslationTokenArrives() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            endMarker(),
        ])
        engine.applyStreamM([translation("Ch", final: false)])

        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertTrue(display.showsTranslatingPlaceholder)
        XCTAssertNil(engine.segments[0].target)
    }

    /// `target == nil` alone is not a real signal - it is only the absence
    /// of a result. Nothing has happened yet for this `me`-language segment,
    /// so nothing should show.
    func test_mePlaceholderDoesNotShowBeforeAnyTranslationSignalArrives() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "final with no target and no translation signal yet must show nothing, not a placeholder")
    }

    // MARK: - Reviewer finding, third round: markers close regardless of
    // `translationStatus` - checked before the status dispatch, never
    // folded into "build text" or silently dropped for a status neither
    // stream ever tags a real word with.

    func test_mEndMarkerTaggedTranslationClosesTheSegmentAndIsNeverAppendedAsTarget() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Hi", final: true, start: 0, end: 500, lang: "en")])
        XCTAssertFalse(engine.segments[0].isFinal)

        engine.applyStreamM([endMarker(status: .translation)])

        XCTAssertTrue(engine.segments[0].isFinal, "<end> tagged 'translation' must still close the segment")
        XCTAssertNil(engine.segments[0].target, "the marker's own text must never be appended as translation text")
    }

    func test_mEndMarkerTaggedUnrecognizedClosesTheSegment() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Chào", final: true, start: 0, end: 500, lang: "vi")])
        XCTAssertFalse(engine.segments[0].isFinal)

        engine.applyStreamM([endMarker(status: .unrecognized)])

        XCTAssertTrue(engine.segments[0].isFinal, "<end> tagged 'unrecognized' must still close the segment, or it never closes at all")
    }

    // MARK: - Live reopen finding 1: `translation_status: "none"` is
    // documented original speech this stream is not translating - it must
    // build/close segments exactly like `.original`, never be silently
    // dropped like an unrecognised value.

    func test_noneStatusTokenOnStreamMBuildsASegmentLikeOriginal() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([noneStatus("Xin chào", final: true, start: 0, end: 1000, lang: "vi")])

        XCTAssertEqual(engine.segments.count, 1, "a 'none'-status token is original speech and must build a segment, same as 'original'")
        XCTAssertEqual(engine.segments[0].source, "Xin chào")
        XCTAssertEqual(engine.segments[0].lang, "vi")
    }

    func test_endMarkerWithNoneStatusClosesTheOpenSegment() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([noneStatus("Xin chào", final: true, start: 0, end: 1000, lang: "vi")])
        XCTAssertFalse(engine.segments[0].isFinal, "sanity: still open before <end>")

        engine.applyStreamM([endMarker(status: .none)])

        XCTAssertTrue(engine.segments[0].isFinal, "<end> tagged 'none' must still close the segment, or segments never close and keep merging unrelated audio")
    }

    /// A genuinely unrecognised status - never the documented `"none"` -
    /// must stay conservative: skipped, not built into a segment, exactly
    /// the old default behaviour, now correctly scoped to only this case.
    func test_unrecognizedStatusTokenOnStreamMIsIgnored() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([unrecognizedStatus("???")])

        XCTAssertTrue(engine.segments.isEmpty, "a genuinely unrecognised status must not build a segment")
    }

    // MARK: - Live reopen finding 2: a closed segment must show only its
    // locked final text, never a non-final tail left over from whichever
    // response last updated it before the close.

    /// A final token from a different speaker cuts a new segment without
    /// ever finalizing the previous segment's own last (still partial)
    /// word - closing must not leave that partial tail baked in.
    func test_segmentClosedBySpeakerChangeHasNoStaleNonFinalTail() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        // A locked final token first (the speaker-change boundary check
        // only fires once `lang` is locked), then a non-final tail that
        // never gets finalized before the speaker changes.
        engine.applyStreamM([original("Hello ", final: true, start: 0, end: 400, speaker: "1", lang: "en")])
        engine.applyStreamM([original("worl", final: false, start: 400, end: 900, speaker: "1", lang: nil)])
        XCTAssertEqual(engine.segments[0].source, "Hello worl", "sanity: the partial tail is showing")

        engine.applyStreamM([original(" Hi", final: true, start: 1000, end: 1200, speaker: "2", lang: "en")])

        XCTAssertTrue(engine.segments[0].isFinal)
        XCTAssertEqual(engine.segments[0].source, "Hello ", "a segment closed by a speaker change must show only its locked final text, never the previous response's partial tail")
    }

    /// The reconnect path closes the open segment the same way - it must
    /// not leave a stale tail baked in either.
    func test_segmentClosedByReconnectHasNoStaleNonFinalTail() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Xin ch", final: false, start: 0, end: 500, speaker: "1", lang: nil)])
        XCTAssertEqual(engine.segments[0].source, "Xin ch")

        engine.closeOpenSegmentForReconnect()

        XCTAssertTrue(engine.segments[0].isFinal)
        XCTAssertEqual(engine.segments[0].source, "", "a segment closed for a reconnect, with no final token of its own, must not keep its partial tail")
    }

    /// Diagnosis for the "two consecutive B segments, both 'Why?'" live
    /// observation: nothing in the engine can duplicate a segment - `id` is
    /// assigned once per genuinely new segment and only ever increases, and
    /// each `<end>` closes exactly the one segment `currentMSegmentId`
    /// names. Two separately `<end>`-bounded utterances with identical text
    /// from the same speaker are two distinct, correct segments, not a sign
    /// of an engine bug - the live case is almost certainly genuine
    /// repetition in the audio.
    func test_twoConsecutiveIdenticalFinalsFromTheSameSpeakerAreTwoDistinctSegmentsNotADuplicate() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Why?", final: true, start: 0, end: 300, speaker: "2", lang: "en"),
            endMarker(),
            original("Why?", final: true, start: 400, end: 700, speaker: "2", lang: "en"),
            endMarker(),
        ])

        XCTAssertEqual(engine.segments.count, 2, "two separately <end>-bounded utterances, even with identical text and the same speaker, must remain two distinct segments")
        XCTAssertEqual(engine.segments[0].id, 1)
        XCTAssertEqual(engine.segments[1].id, 2)
    }

    // MARK: - Re-review finding 3: the M-direct placeholder is a live signal,
    // not a timer - it must not clear while the signal is present, must not
    // linger after it is gone, and the state must never be contradictory
    // (abandoned and translated at once).

    /// "No early clear": a second response that STILL carries a non-final
    /// translation token for the same segment means the signal is still
    /// present - must not clear.
    func test_mDirectPlaceholderDoesNotClearWhileTheNonFinalSignalIsStillPresent() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            translation("Ch", final: false),
        ])
        XCTAssertTrue(engine.segments[0].translationInProgress)

        engine.applyStreamM([translation("Chào", final: false)])

        XCTAssertTrue(engine.segments[0].translationInProgress, "must not clear while the non-final translation signal is still present")
    }

    /// "No linger": non-final tokens are replaced in full on every
    /// response, so a later response with none at all for this segment
    /// means the signal has genuinely disappeared - hide the placeholder
    /// immediately, not on some later timer.
    func test_mDirectPlaceholderClearsAsSoonAsTheNonFinalSignalDisappearsWithNoFinalChunk() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            translation("Ch", final: false),
            endMarker(),
        ])
        XCTAssertTrue(engine.segments[0].translationInProgress, "sanity: signal present right after the first response")

        // A later response with nothing for this segment's translation.
        engine.applyStreamM([])

        XCTAssertFalse(engine.segments[0].translationInProgress, "must clear as soon as the live signal disappears, not linger")
        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder)
    }

    /// "No contradictory state": once the signal disappeared and the
    /// placeholder cleared, a late final translation chunk on the same
    /// (M-direct, same-stream, ordered) connection must still land
    /// cleanly - never leaving the segment both `targetAbandoned` and
    /// translated at once.
    func test_mDirectLateFinalTranslationLandsCleanlyNeverContradictingAnAbandonedState() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            translation("Ch", final: false),
            endMarker(),
        ])
        engine.applyStreamM([])
        XCTAssertFalse(engine.segments[0].translationInProgress, "sanity: placeholder already cleared")

        engine.applyStreamM([translation("Chào", final: true)])

        XCTAssertEqual(engine.segments[0].target, "Chào", "a late final translation must still land")
        XCTAssertFalse(engine.segments[0].targetAbandoned, "must never be simultaneously abandoned and translated")
    }

    // MARK: - Issue 4: reconnect

    /// Issue 4: post-reconnect raw speaker ids must never silently reuse a
    /// letter already shown pre-reconnect, since the app does not actually
    /// know a post-drop "1" is the same person as any pre-drop speaker.
    func test_streamMReconnectNeverReusesAPreDropLetterForANewRawId() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"), endMarker()])
        XCTAssertEqual(engine.segments[0].speaker, "A")

        engine.handleStreamMReconnected()

        // The reconnected socket's diarization restarts its own numbering
        // and could easily call the same person "1" again - the app has no
        // way to know that, so it must not display it as "A" again.
        engine.applyStreamM([original("Hi again", final: true, start: 600, end: 900, speaker: "1", lang: "en")])

        XCTAssertEqual(engine.segments.count, 2, "a new segment must start after the reconnect")
        XCTAssertEqual(engine.segments[1].speaker, "B", "a post-reconnect raw id must get a fresh letter, never one already shown pre-reconnect")
    }

    /// Distinct raw ids still get distinct letters in order of first
    /// appearance - not by their numeric value - since diarization is not
    /// guaranteed to hand out "1" to whoever spoke first.
    func test_speakerLettersAssignedInOrderOfFirstAppearanceNotByRawIdValue() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Hi", final: true, start: 0, end: 500, speaker: "7", lang: "en")])
        XCTAssertEqual(engine.segments[0].speaker, "A", "whichever raw id speaks first gets A, regardless of its numeric value")

        engine.applyStreamM([original(" Hey", final: true, start: 600, end: 900, speaker: "3", lang: "en")])
        XCTAssertEqual(engine.segments[1].speaker, "B")

        engine.applyStreamM([original(" Again", final: true, start: 1000, end: 1300, speaker: "7", lang: "en")])
        XCTAssertEqual(engine.segments[2].speaker, "A", "the same raw id, still within the same connection, must keep its earlier letter")
    }

    /// A reconnect tears down and reopens M too, so a non-`me` segment
    /// whose M-direct translation was already under way (but not yet
    /// complete) when the drop happened must also stop showing
    /// "Đang dịch…" - M's old connection is gone and nothing will ever
    /// finish it.
    func test_reconnectAbandonsAnInProgressNonMeMDirectTranslationToo() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            endMarker(),
        ])
        engine.applyStreamM([translation("Ch", final: false)])
        var display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertTrue(display.showsTranslatingPlaceholder, "sanity check: the M-direct translation is genuinely in progress")

        engine.abandonMDirectTranslationsInProgress()

        XCTAssertTrue(engine.segments[0].targetAbandoned, "an in-progress M-direct translation must be abandoned on reconnect")
        display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "must not keep showing Đang dịch… against a connection that no longer exists")
    }

    /// Option C: on-device `me -> target` translation does not depend on
    /// the Soniox socket at all, so an M reconnect must never touch a
    /// `me`-language segment's translation state - unlike the non-`me`
    /// case above.
    func test_reconnectNeverAbandonsAMeLanguageSegmentsTranslationInProgress() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        engine.applyTranslationStarted(segmentId: engine.segments[0].id)
        XCTAssertTrue(engine.segments[0].translationInProgress)

        engine.abandonMDirectTranslationsInProgress()

        XCTAssertTrue(engine.segments[0].translationInProgress, "an M reconnect must never abandon on-device translation, which does not depend on the Soniox socket")
        XCTAssertFalse(engine.segments[0].targetAbandoned)
    }

    /// Re-review finding 3: the M segment still open at the moment of a
    /// drop must be closed, or post-drop tokens silently join it under its
    /// pre-drop label. The non-final tail path (unlike the final-token
    /// boundary check) has no speaker/language comparison at all, so this
    /// is only exploitable through a non-final post-drop token - which is
    /// exactly what a real reconnect's first tokens are likely to be.
    func test_reconnectClosesTheOpenPreDropSegmentSoPostDropTokensDontJoinIt() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Xin", final: true, start: 0, end: 400, speaker: "1", lang: "vi")])
        XCTAssertFalse(engine.segments[0].isFinal, "sanity: segment 1 is still open, no <end> yet")

        engine.closeOpenSegmentForReconnect()
        engine.abandonMDirectTranslationsInProgress()
        engine.handleStreamMReconnected()
        XCTAssertTrue(engine.segments[0].isFinal, "the pre-drop open segment must be closed at the drop")

        engine.applyStreamM([original("Hello", final: false, start: 5000, end: 5300, speaker: "1", lang: "vi")])

        XCTAssertEqual(engine.segments.count, 2, "a post-drop token must start a new segment, never join the pre-drop open one")
        XCTAssertEqual(engine.segments[0].source, "Xin", "the pre-drop segment's text must not gain any post-drop content")
    }

    // MARK: - On-device me -> target translation lifecycle (option C)

    func test_onMeSegmentFinalizedFiresWithTheSegmentsFinalSourceText() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        var fired: (id: Int, source: String)?
        engine.onMeSegmentFinalized = { fired = ($0, $1) }

        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        XCTAssertEqual(fired?.id, engine.segments[0].id)
        XCTAssertEqual(fired?.source, "Xin chào")
    }

    func test_onMeSegmentFinalizedNeverFiresForANonMeSegment() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        var fired = false
        engine.onMeSegmentFinalized = { _, _ in fired = true }

        engine.applyStreamM([
            original("Hi", final: true, start: 0, end: 500, speaker: "1", lang: "en"),
            endMarker(),
        ])

        XCTAssertFalse(fired, "only me-language segments are ever sent for on-device translation")
    }

    /// Empty or whitespace-only source is never sent (the outcome's
    /// fatalError rule 8).
    func test_onMeSegmentFinalizedNeverFiresForBlankSource() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        var fired = false
        engine.onMeSegmentFinalized = { _, _ in fired = true }

        engine.applyStreamM([
            original("   ", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        XCTAssertFalse(fired, "whitespace-only final text must never be sent for translation")
    }

    func test_applyTranslationStartedShowsThePlaceholder() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        let id = engine.segments[0].id
        XCTAssertFalse(SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true).showsTranslatingPlaceholder, "sanity: nothing showing yet")

        engine.applyTranslationStarted(segmentId: id)

        XCTAssertTrue(SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true).showsTranslatingPlaceholder)
    }

    func test_applyTranslationSuccessWritesTheWholeTargetOnceAndClearsThePlaceholder() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        let id = engine.segments[0].id
        engine.applyTranslationStarted(segmentId: id)

        engine.applyTranslationSuccess(segmentId: id, target: "Hello")

        XCTAssertEqual(engine.segments[0].target, "Hello")
        XCTAssertFalse(engine.segments[0].targetAbandoned)
        XCTAssertFalse(SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true).showsTranslatingPlaceholder)
    }

    /// An error means "no translation", never a retry (fatalError rule 8).
    func test_applyTranslationFailureAbandonsAndClearsThePlaceholderWithNoTarget() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        let id = engine.segments[0].id
        engine.applyTranslationStarted(segmentId: id)

        engine.applyTranslationFailure(segmentId: id)

        XCTAssertNil(engine.segments[0].target)
        XCTAssertTrue(engine.segments[0].targetAbandoned)
        XCTAssertFalse(SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true).showsTranslatingPlaceholder)
    }

    func test_applyTranslationSuccessAfterFailureIsANoOpAbandonmentIsPermanent() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        let id = engine.segments[0].id
        engine.applyTranslationFailure(segmentId: id)

        engine.applyTranslationStarted(segmentId: id)

        XCTAssertFalse(engine.segments[0].translationInProgress, "an already-abandoned segment must never be revived by a stray later report")
    }

    // MARK: - Review round 3, finding 7: never cut a segment inside a word.
    // Live evidence: diarization flipped speaker between the subword tokens
    // "B" and "ạn" of "Bạn", and the old rule cut on ANY final-token
    // speaker/language change, splitting "Bạn nghề gì?" into a lone "B"
    // (labelled B) and "ạn nghề gì?" (labelled A). A continuation token -
    // one whose text does not start with whitespace - must stay in the
    // open segment regardless of what speaker/language it itself carries.

    func test_finalTokenWithNoLeadingWhitespaceNeverCutsANewSegmentEvenOnASpeakerChange() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("B", final: true, start: 0, end: 100, speaker: "1", lang: "vi")])
        XCTAssertEqual(engine.segments.count, 1)

        engine.applyStreamM([original("ạn nghề gì?", final: true, start: 100, end: 900, speaker: "2", lang: "vi")])

        XCTAssertEqual(engine.segments.count, 1, "a continuation token (no leading whitespace) must never cut a new segment, even with a different speaker")
        XCTAssertEqual(engine.segments[0].source, "Bạn nghề gì?")
        XCTAssertEqual(engine.segments[0].speaker, "A", "the segment's speaker stays the label of its FIRST token, never inferred from a later continuation")
    }

    func test_finalTokenWithNoLeadingWhitespaceNeverCutsANewSegmentEvenOnALanguageChange() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Chào", final: true, start: 0, end: 400, speaker: "1", lang: "vi")])
        engine.applyStreamM([original("ish", final: true, start: 400, end: 700, speaker: "1", lang: "en")])

        XCTAssertEqual(engine.segments.count, 1, "a continuation token must never cut on a language change either")
        XCTAssertEqual(engine.segments[0].source, "Chàoish")
        XCTAssertEqual(engine.segments[0].lang, "vi", "the locked language stays the first token's, never the continuation's")
    }

    func test_finalTokenWithLeadingWhitespaceStillCutsOnASpeakerChange() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([original("Chào", final: true, start: 0, end: 400, speaker: "1", lang: "vi")])
        XCTAssertEqual(engine.segments.count, 1)

        engine.applyStreamM([original(" Hi", final: true, start: 400, end: 700, speaker: "2", lang: "en")])

        XCTAssertEqual(engine.segments.count, 2, "a genuine new-word token must still cut a new segment on a speaker/language change")
        XCTAssertEqual(engine.segments[0].source, "Chào")
        XCTAssertEqual(engine.segments[1].source, " Hi")
        XCTAssertEqual(engine.segments[1].speaker, "B")
    }

    /// The first token after a marker is always a boundary, regardless of
    /// leading whitespace - a marker already closes the previous segment.
    func test_firstTokenAfterAMarkerStartsANewSegmentEvenWithNoLeadingWhitespace() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Chào", final: true, start: 0, end: 400, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        engine.applyStreamM([original("tiếp", final: true, start: 500, end: 900, speaker: "1", lang: "vi")])

        XCTAssertEqual(engine.segments.count, 2, "a marker already closed the previous segment - the next token always starts a new one")
    }
}
