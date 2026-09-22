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

    /// Live-confirmed: original (spoken) text this stream is not
    /// translating, because it is already in this stream's own target
    /// language - see docs/soniox-routing.md's Unknowns table.
    private func noneStatus(_ text: String, final: Bool, start: Int?, end: Int?, speaker: String? = "1", lang: String?) -> SonioxToken {
        SonioxToken(text: text, isFinal: final, startMs: start, endMs: end, speaker: speaker, language: lang, translationStatus: .none)
    }

    private func endMarkerWithNoneStatus() -> SonioxToken {
        SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .none)
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

    // MARK: - No-guess join: clean case

    func test_cleanJoinFillsTargetFromStreamT() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        XCTAssertNil(engine.segments[0].target)

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            translation("Hello"),
            endMarker(), // T's own <end>: the "complete" signal, not a timer
        ])

        XCTAssertEqual(engine.segments[0].target, "Hello")
        XCTAssertFalse(engine.segments[0].targetAbandoned)
    }

    /// Re-review: `target == nil` alone is not a real signal - it is only
    /// the absence of a result. Nothing from T has happened yet here, so
    /// nothing should show - the exact case the review flagged against the
    /// previous version of this test, which asserted the opposite.
    func test_placeholderDoesNotShowBeforeAnyRealTranslationSignalArrives() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "final with no target and no translation signal yet must show nothing, not a placeholder")
    }

    /// Once T actually starts translating this window - even with only a
    /// non-final translation token - the placeholder may show: a real
    /// signal from the contributing stream, not a guess. The non-final
    /// text itself must never be committed to `target` (no karaoke reveal
    /// of a partial translation, per HANDOFF section 6).
    func test_placeholderShowsOnceARealNonFinalTranslationSignalArrivesFromT() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            translation("Hel", final: false),
        ])

        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertTrue(display.showsTranslatingPlaceholder, "a non-final translation token is a real signal that translation is under way")
        XCTAssertNil(engine.segments[0].target, "a non-final translation token must never be committed to target")
    }

    /// The non-`me` (M-direct) side of the same rule: nothing shows before
    /// M has sent any translation token for this segment.
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

    /// Issue 2: independent streams do not guarantee arrival order. T can
    /// see and translate the owner's own chunk before M gets around to
    /// closing that segment with `<end>`. The translation must not be lost
    /// just because no pending join existed yet when T's tokens arrived.
    func test_translationArrivingBeforeMClosesTheSegmentStillLands() {
        let engine = SonioxJoinEngine(meLanguage: "vi")

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            translation("Hello"),
        ])

        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        engine.applyStreamT([endMarker()]) // T's own <end>, replayed against the now-open window

        XCTAssertEqual(engine.segments[0].target, "Hello", "a translation that arrived before M closed the segment must not be lost")
        XCTAssertFalse(engine.segments[0].targetAbandoned)
    }

    /// The same ordering case, but the pre-close T tokens belong to a
    /// window that turns out disqualified once replayed - the buffer must
    /// not somehow bypass the certainty test.
    func test_translationArrivingBeforeMClosesStillRespectsDisqualification() {
        let engine = SonioxJoinEngine(meLanguage: "vi")

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 400, speaker: "1", lang: "vi"),
            original("hi there", final: true, start: 450, end: 900, speaker: "2", lang: "en"),
            translation("hi there in target"),
        ])

        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        // Disqualification (check 1) is synchronous, the moment the
        // wrong-language original replays against the newly opened window -
        // no further T signal is needed to observe it.
        XCTAssertNil(engine.segments[0].target, "replaying buffered tokens must not bypass the no-guess certainty test")
        XCTAssertTrue(engine.segments[0].targetAbandoned)
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

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 400, speaker: "1", lang: "vi"),
            original("hi there", final: true, start: 450, end: 900, speaker: "2", lang: "en"), // the guest, overlapping
            translation("hi there in target"), // belongs to the guest's chunk, not the owner's
        ])

        XCTAssertNil(engine.segments[0].target, "must never attach the guest's translation to the owner's line")
        XCTAssertTrue(engine.segments[0].targetAbandoned, "the join must be recorded as abandoned, not merely still pending")

        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "an abandoned join must never keep showing Đang dịch…")
    }

    /// Issue 3b: disqualification must stop the placeholder immediately -
    /// it is a synchronous check, never gated on any later resolution
    /// signal (T's next original, its `<end>`, or otherwise).
    func test_disqualificationStopsThePlaceholderImmediatelyNotAtResolveTime() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        // Only the disqualifying guest token arrives - no resolving signal
        // (no T <end>, no next-window original) has happened yet.
        engine.applyStreamT([original("hi there", final: true, start: 450, end: 900, speaker: "2", lang: "en")])

        XCTAssertTrue(engine.segments[0].targetAbandoned, "disqualification must mark abandoned the moment it happens, not wait for resolveJoins")
        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder)
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

        // Check 2 must abandon the segment immediately, before T ever says anything.
        XCTAssertTrue(engine.segments[0].targetAbandoned)

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            translation("Hello"),
        ])

        XCTAssertNil(engine.segments[0].target, "M's own detected overlap must disqualify the join, per check 2")
        XCTAssertTrue(engine.segments[0].targetAbandoned)
    }

    /// If T genuinely never sends anything at all for a window - no
    /// translation, no next original, no `<end>` - there is no real signal
    /// to resolve on in either direction: the join must stay pending, not
    /// be guessed into "abandoned" just because nothing has happened yet.
    /// Abandoning on silence would be exactly as much a guess as showing a
    /// translation would be. A genuine end - T's own `<end>`/`<fin>`, its
    /// next original chunk, or a reconnect/session end via
    /// `abandonAllPendingJoins` - is what actually settles it.
    func test_noTSignalAtAllLeavesTheJoinPendingNeverGuessingAbandoned() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        XCTAssertNil(engine.segments[0].target)
        XCTAssertFalse(engine.segments[0].targetAbandoned, "no signal from T at all must never be guessed into a permanent abandon")
        let display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "no signal from T at all means no placeholder either - the AGENTS.md activity-indicator rule")
    }

    // MARK: - Issue 4: reconnect

    /// A reconnect invalidates the shared time origin the join relies on:
    /// every join still in flight must be abandoned immediately, not left
    /// to time out on its own (which could take arbitrarily long, or never
    /// happen if the surviving stream never reports a later
    /// `final_audio_proc_ms` for that window again).
    func test_abandonAllPendingJoinsStopsEveryInFlightPlaceholderAtOnce() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        XCTAssertFalse(engine.segments[0].targetAbandoned)

        engine.abandonAllPendingJoins()

        XCTAssertTrue(engine.segments[0].targetAbandoned)
        XCTAssertNil(engine.segments[0].target)

        // A T token for the now-abandoned window must not resurrect it.
        engine.applyStreamT([original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"), translation("Hello")])
        XCTAssertNil(engine.segments[0].target, "an abandoned window must never be revived by a stray later token")
    }

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

        engine.applyStreamM([original("Hey", final: true, start: 600, end: 900, speaker: "3", lang: "en")])
        XCTAssertEqual(engine.segments[1].speaker, "B")

        engine.applyStreamM([original("Again", final: true, start: 1000, end: 1300, speaker: "7", lang: "en")])
        XCTAssertEqual(engine.segments[2].speaker, "A", "the same raw id, still within the same connection, must keep its earlier letter")
    }

    /// This round: `SonioxLiveSession` now reconnects both sockets
    /// together on any drop, so it always calls both
    /// `abandonAllPendingJoins()` and `handleStreamMReconnected()` for
    /// every reconnect, regardless of which socket actually dropped - the
    /// engine must support both effects landing together, not just each in
    /// isolation.
    func test_reconnectAbandonsInFlightJoinsAndResetsSpeakerLettersTogether() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])
        XCTAssertEqual(engine.segments[0].speaker, "A")
        XCTAssertFalse(engine.segments[0].targetAbandoned)

        engine.abandonAllPendingJoins()
        engine.handleStreamMReconnected()

        XCTAssertTrue(engine.segments[0].targetAbandoned, "the pre-drop join must be abandoned")

        engine.applyStreamM([original("New", final: true, start: 2000, end: 2500, speaker: "1", lang: "vi")])

        XCTAssertEqual(engine.segments[1].speaker, "B", "a reconnect must never let a post-drop speaker reuse a pre-drop letter")
    }

    /// A reconnect always tears down and reopens M too, so a non-`me`
    /// segment whose M-direct translation was already under way (but not
    /// yet complete) when the drop happened must also stop showing
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

        engine.abandonAllPendingJoins()

        XCTAssertTrue(engine.segments[0].targetAbandoned, "an in-progress M-direct translation must be abandoned on reconnect, same as a T-join window")
        display = SegmentDisplay.make(for: engine.segments[0], isActivityRunning: true)
        XCTAssertFalse(display.showsTranslatingPlaceholder, "must not keep showing Đang dịch… against a connection that no longer exists")
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
        engine.abandonAllPendingJoins()
        engine.handleStreamMReconnected()
        XCTAssertTrue(engine.segments[0].isFinal, "the pre-drop open segment must be closed at the drop")

        engine.applyStreamM([original("Hello", final: false, start: 5000, end: 5300, speaker: "1", lang: "vi")])

        XCTAssertEqual(engine.segments.count, 2, "a post-drop token must start a new segment, never join the pre-drop open one")
        XCTAssertEqual(engine.segments[0].source, "Xin", "the pre-drop segment's text must not gain any post-drop content")
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

    // MARK: - Live reopen finding 1: `translation_status: "none"` is
    // documented original speech this stream is not translating - it must
    // build/close segments exactly like `.original`, on both streams,
    // including `<end>`/`<fin>` markers - never be silently dropped like an
    // unrecognised value.

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

        engine.applyStreamM([endMarkerWithNoneStatus()])

        XCTAssertTrue(engine.segments[0].isFinal, "<end> tagged 'none' must still close the segment, or segments never close and keep merging unrelated audio")
    }

    /// The T-side half of the same mistake: a 'none'-status original token
    /// on stream T (speech already in `target`) is a real original token for
    /// the join's check 1 - the guest speaking `target` overlapping a `me`
    /// window must still disqualify the join, exactly as an `.original`
    /// token would.
    func test_noneStatusOriginalOnStreamTStillDisqualifiesOverlappingJoin() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 1000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 400, speaker: "1", lang: "vi"),
            noneStatus("hi there", final: true, start: 450, end: 900, speaker: "2", lang: "en"), // the guest, already in target, overlapping
            translation("hi there in target"),
        ])

        XCTAssertNil(engine.segments[0].target, "a 'none'-status overlapping token must disqualify the join just like an 'original' one would")
        XCTAssertTrue(engine.segments[0].targetAbandoned)
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

        engine.applyStreamM([original("Hi", final: true, start: 1000, end: 1200, speaker: "2", lang: "en")])

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

    // MARK: - Live reopen, second session: resolving a T-join on
    // `final_audio_proc_ms` catching up to `segmentEnd` - instead of on a
    // real T signal - truncated or dropped `me`-segment translations,
    // because translation chunks carry no timestamp and trail their
    // original, sometimes into a later response than the audio watermark
    // that timing rule fired on.

    /// The exact "của What's Up English" symptom: a translation split
    /// across two responses, with nothing on T but the trailing chunk in
    /// the second one, must still assemble in full - never truncate at
    /// whatever happened to be the first response's chunk.
    func test_translationSplitAcrossTwoResponsesStillAssemblesInFull() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Chào các bạn", final: true, start: 0, end: 2000, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        engine.applyStreamT([
            original("Chào các bạn", final: true, start: 0, end: 2000, speaker: "1", lang: "vi"),
            translation("Hello everyone"),
        ])
        // A later response with only the trailing translation chunk - no
        // original token of its own, since it belongs to the same speech.
        engine.applyStreamT([
            translation(" from What's Up English"),
            endMarker(),
        ])

        XCTAssertEqual(engine.segments[0].target, "Hello everyone from What's Up English", "a translation split across two responses must assemble in full, never truncate at a response boundary")
    }

    /// The "Bạn có nghe được tiếng Việt không?" symptom: T's original
    /// arrives with no translation chunk yet - the translation itself
    /// trails into a later response. It must still land, not be lost to an
    /// early resolve that gave up before it ever arrived.
    func test_translationArrivingInALaterResponseThanItsOriginalStillLands() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Bạn có nghe được tiếng Việt không?", final: true, start: 0, end: 1500, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        engine.applyStreamT([
            original("Bạn có nghe được tiếng Việt không?", final: true, start: 0, end: 1500, speaker: "1", lang: "vi"),
        ])
        XCTAssertNil(engine.segments[0].target, "sanity: nothing landed yet")
        XCTAssertFalse(engine.segments[0].targetAbandoned, "sanity: not abandoned yet either - the translation may simply not have started")

        engine.applyStreamT([
            translation("Can you understand Vietnamese?"),
            endMarker(),
        ])

        XCTAssertEqual(engine.segments[0].target, "Can you understand Vietnamese?", "a translation arriving in a later response, with no intervening T original for a different window, must still land")
    }

    /// T's own next original chunk - for a genuinely different, later
    /// window - is itself a real "complete" signal: it must resolve the
    /// PREVIOUS window with exactly what was collected for it, and start
    /// collecting fresh for the new one, never mixing the two.
    func test_nextTOriginalForADifferentWindowResolvesThePreviousJoin() {
        let engine = SonioxJoinEngine(meLanguage: "vi")
        engine.applyStreamM([
            original("Xin chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            endMarker(),
            original("Tạm biệt", final: true, start: 1000, end: 1500, speaker: "1", lang: "vi"),
            endMarker(),
        ])

        engine.applyStreamT([
            original("Xin chào", final: true, start: 0, end: 500, speaker: "1", lang: "vi"),
            translation("Hello"),
            // T moves on to the second window's original before ever
            // sending its own <end> for the first.
            original("Tạm biệt", final: true, start: 1000, end: 1500, speaker: "1", lang: "vi"),
            translation("Goodbye"),
            endMarker(),
        ])

        XCTAssertEqual(engine.segments[0].target, "Hello", "T's next original for a different window must resolve the previous one with exactly what it collected")
        XCTAssertEqual(engine.segments[1].target, "Goodbye")
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
}
