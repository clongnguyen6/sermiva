import Foundation

/// Everything a transcript row needs to decide whether an activity
/// indicator shows for one segment - the recognizing tag and its pulsing
/// dot, the caret, the "Dang dich..." placeholder and its spinner, the
/// VoiceOver "updates frequently" trait, and the language label - computed
/// once here from the segment's own shape and whether the session is
/// genuinely running (`DemoSessionController.isActivityRunning`). This is
/// the single place that combines the two; `CaptionsTranscriptView` only
/// reads the result, so there is nowhere left in the view for any one of
/// these to independently forget the "genuinely running" half of the rule.
struct SegmentDisplay: Equatable {
    let segment: Segment
    let showsRecognizingTag: Bool
    let showsCaret: Bool
    let showsTranslatingPlaceholder: Bool
    let updatesFrequently: Bool
    /// `nil` means show nothing at that position - not fallback text. Only
    /// `segment.lang == nil` (diarization has not identified the language
    /// yet) is gated on `isActivityRunning`; a known language is a settled
    /// fact, not a claim of ongoing activity, so it always shows.
    let languageText: String?
    /// `segment.source` with any leading whitespace dropped - Soniox tokens
    /// carry their own leading space (live-confirmed: " My husband..."),
    /// which is correct for joining tokens together but must not show as a
    /// leading gap at the start of the line. Only the leading edge is
    /// trimmed; the spacing between words inside `segment.source` itself is
    /// untouched.
    let sourceText: String
    /// Same trim as `sourceText`, applied to `segment.target` - `nil` stays
    /// `nil`, never becomes an empty string.
    let targetText: String?

    static func make(for segment: Segment, isActivityRunning: Bool) -> SegmentDisplay {
        let isPartial = !segment.isFinal
        // `target == nil` alone is not a real signal - it is just the
        // absence of a result. `translationInProgress` is set only once a
        // real translation token has actually arrived (or, for demo, once
        // the fixture has committed to filling it); without that, per
        // AGENTS.md's activity-indicator invariant, nothing shows.
        let awaitingTranslation = segment.isFinal && segment.target == nil && !segment.targetAbandoned && segment.translationInProgress
        return SegmentDisplay(
            segment: segment,
            showsRecognizingTag: isPartial && isActivityRunning,
            showsCaret: isPartial && isActivityRunning,
            showsTranslatingPlaceholder: awaitingTranslation && isActivityRunning,
            updatesFrequently: isPartial && isActivityRunning,
            languageText: segment.lang.map(LanguageNames.display) ?? (isActivityRunning ? "Đang nhận diện ngôn ngữ" : nil),
            sourceText: Self.trimmingLeadingWhitespace(segment.source),
            targetText: segment.target.map(Self.trimmingLeadingWhitespace)
        )
    }

    private static func trimmingLeadingWhitespace(_ text: String) -> String {
        String(text.drop { $0.isWhitespace })
    }
}
