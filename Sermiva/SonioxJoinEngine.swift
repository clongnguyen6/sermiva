import Foundation

/// Builds `Segment` values from Soniox stream M (translated into `me`) -
/// the sole source of segments (text, language, speakers, boundaries) and
/// of the translation for every non-`me` segment. Per docs/soniox-routing.md
/// (option C), a `me`-language segment's `target` is no longer filled by a
/// second Soniox stream and a join - it comes from on-device Apple
/// Translation, driven by `LiveSessionController`/`SonioxLiveSession`
/// through `onMeSegmentFinalized` below and the `applyTranslation...`
/// methods, which this engine still owns so `segments` has exactly one
/// writer. Pure, app-owned logic: it consumes `SonioxToken` batches, never
/// raw wire JSON or a live socket, so it is testable without the WebSocket
/// adapter - the boundary AGENTS.md and the outcome brief both require.
///
/// Only final tokens drive segment text and committed translation text.
/// Non-final tokens still update the currently open segment's displayed
/// source text in place, the same spirit as `SegmentAssembler`'s partial
/// handling for demo playback.
@MainActor
final class SonioxJoinEngine {
    private(set) var segments: [Segment] = []

    let meLanguage: String

    /// Fired exactly once per segment, the instant a `me`-language segment
    /// is finalized with non-blank text - `(segmentId, finalSourceText)`.
    /// `LiveSessionController`/`SonioxLiveSession` enqueue this for
    /// on-device translation; this engine never calls Apple's Translation
    /// framework itself.
    var onMeSegmentFinalized: ((Int, String) -> Void)?

    private var nextId = 1
    /// The id of the M segment that final original tokens (and any
    /// translation tokens trailing them) currently belong to. Sticks past
    /// `<end>` until a genuinely new segment starts, so a translation chunk
    /// arriving after its segment's own `<end>` still lands correctly (SDK
    /// source: original chunk, then its translation chunk, same speaker).
    private var currentMSegmentId: Int?
    /// Whether `currentMSegmentId` is still open (no `<end>`/boundary yet).
    private var isCurrentMSegmentOpen = false
    /// The permanently-locked (final) source text per segment id. `source`
    /// on the segment itself is recomputed each response as this plus the
    /// current response's own non-final tail - never accumulated across
    /// responses - because non-final tokens are replaced in full on every
    /// response, not appended to (docs/soniox-routing.md).
    private var finalSourceById: [Int: String] = [:]

    /// Raw Soniox speaker id ("1", "2", ...) to the app-assigned letter,
    /// for the current M connection only. Assigned in order of first
    /// appearance within that connection - not by the raw id's numeric
    /// value - since diarization is not guaranteed to hand out "1" to
    /// whoever speaks first. Cleared (but `nextSpeakerLetterIndex` is not)
    /// on `handleStreamMReconnected`, so a post-reconnect raw id never
    /// silently reuses a letter already shown pre-reconnect - see that
    /// method and docs/soniox-routing.md's reconnecting section.
    private var speakerLetterByRawId: [String: String] = [:]
    private var nextSpeakerLetterIndex = 0

    private func label(forRawSpeaker raw: String?) -> String? {
        guard let raw else { return nil }
        if let existing = speakerLetterByRawId[raw] { return existing }
        guard nextSpeakerLetterIndex < 26 else { return nil }
        let letter = String(UnicodeScalar(UInt8(ascii: "A") + UInt8(nextSpeakerLetterIndex)))
        speakerLetterByRawId[raw] = letter
        nextSpeakerLetterIndex += 1
        return letter
    }

    init(meLanguage: String) {
        self.meLanguage = meLanguage
    }

    // MARK: - Reconnect (docs/soniox-routing.md's reconnecting section)

    /// M's diarization restarts its own speaker numbering after a
    /// reconnect, so a post-reconnect raw id "1" is not known to be the
    /// same person as any pre-reconnect speaker. Clearing the raw-id map
    /// (without resetting the letter counter) means the next new speaker
    /// gets a letter never shown before, rather than silently reusing "A"
    /// for someone who is not provably the original "A".
    func handleStreamMReconnected() {
        speakerLetterByRawId.removeAll()
    }

    /// A reconnect tears down and reopens M: a non-`me` segment whose
    /// M-direct translation was already under way but not yet complete when
    /// the drop happened must stop showing "Đang dịch…" - M's old
    /// connection is gone, so nothing is ever coming to finish it. On-device
    /// `me`-language translation is unaffected by an M reconnect - it does
    /// not depend on the Soniox socket at all - so this never touches a
    /// `me`-language segment; see docs/soniox-routing.md's reconnecting
    /// section.
    func abandonMDirectTranslationsInProgress() {
        for index in segments.indices {
            let segment = segments[index]
            guard segment.isFinal, segment.target == nil, segment.translationInProgress,
                  !segment.targetAbandoned, segment.lang != meLanguage else { continue }
            segments[index].targetAbandoned = true
        }
    }

    /// Called before the above, when a reconnect begins: the M segment
    /// open at the moment of the drop must be closed exactly like a
    /// genuine `<end>` would close it - otherwise it keeps absorbing
    /// tokens from the brand-new post-reconnect connection under its
    /// pre-drop label and locked language, since neither the non-final
    /// tail path nor a same-speaker/same-language final token would ever
    /// cut a new boundary for it on their own.
    func closeOpenSegmentForReconnect() {
        if isCurrentMSegmentOpen, let id = currentMSegmentId {
            closeSegment(id: id)
        }
        isCurrentMSegmentOpen = false
    }

    // MARK: - Stream M

    func applyStreamM(_ tokens: [SonioxToken]) {
        var tailBySegment: [Int: String] = [:]
        var sawTranslationTokenThisResponse = false
        for token in tokens {
            // Markers close the open segment regardless of
            // `translationStatus` - not documented as reliably tagged
            // `.original`/`.none`, and never logged live to confirm either
            // way: by inspection, the previous dispatch order would have
            // appended one to translation text as `.translation`, or
            // silently dropped one entirely as `.unrecognized`, leaving the
            // segment never closed. Checked before the status dispatch on
            // purpose, so a marker never reaches either path.
            if isEndMarker(token) {
                if isCurrentMSegmentOpen, let id = currentMSegmentId {
                    closeSegment(id: id)
                }
                isCurrentMSegmentOpen = false
                continue
            }
            switch token.translationStatus {
            case .original, .none:
                // `.none` on stream M (target_language = me) is speech
                // already in `me` - nothing for this stream to translate,
                // but still real original text that must build/close
                // segments exactly like `.original` does
                // (docs/soniox-routing.md's Unknowns table).
                applyMOriginal(token, tailBySegment: &tailBySegment)
            case .translation:
                applyMTranslation(token)
                sawTranslationTokenThisResponse = true
            case .unrecognized:
                continue
            }
        }
        if isCurrentMSegmentOpen, let id = currentMSegmentId, let index = segments.firstIndex(where: { $0.id == id }) {
            segments[index].source = (finalSourceById[id] ?? "") + (tailBySegment[id] ?? "")
        }
        clearStaleMDirectTranslationSignal(sawTranslationTokenThisResponse: sawTranslationTokenThisResponse)
    }

    /// Non-final tokens are replaced in full on every response
    /// (docs/soniox-routing.md) - so "the latest M response still carries
    /// a translation token for this segment" is itself the live
    /// "translation is under way" signal, not just its first appearance.
    /// If a later response has none at all for the segment M-direct
    /// translation is currently tracking, that signal has genuinely
    /// disappeared: this hides the placeholder (`translationInProgress =
    /// false`) - it does NOT permanently abandon the segment. A later
    /// response bringing the (possibly final) translation after all sets
    /// `translationInProgress` true again via `applyMTranslation`, or
    /// lands `target` directly - so a late final translation always lands
    /// cleanly, and `targetAbandoned` is never set by this path at all,
    /// which is what makes "abandoned and translated at once" impossible
    /// here. `targetAbandoned` for a non-`me` segment still only ever
    /// comes from `startNewMSegment`'s "M moved on to a new segment with
    /// nothing landed" rule, or from a reconnect - both genuinely
    /// permanent, unlike a single quiet response.
    private func clearStaleMDirectTranslationSignal(sawTranslationTokenThisResponse: Bool) {
        guard !sawTranslationTokenThisResponse, let id = currentMSegmentId,
              let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let segment = segments[index]
        guard segment.translationInProgress, segment.target == nil, segment.lang != meLanguage else { return }
        segments[index].translationInProgress = false
    }

    private func isEndMarker(_ token: SonioxToken) -> Bool {
        token.text == "<end>" || token.text == "<fin>"
    }

    /// Markers are filtered out by `applyStreamM` before this is ever
    /// called - every token reaching here is genuine original text.
    private func applyMOriginal(_ token: SonioxToken, tailBySegment: inout [Int: String]) {
        let speakerLabel = label(forRawSpeaker: token.speaker)

        if !isCurrentMSegmentOpen {
            startNewMSegment(firstToken: token, label: speakerLabel)
            if !token.isFinal, let id = currentMSegmentId {
                tailBySegment[id, default: ""] += token.text
            }
            return
        }

        if !token.isFinal {
            if let id = currentMSegmentId {
                tailBySegment[id, default: ""] += token.text
            }
            return
        }

        guard let id = currentMSegmentId, let index = segments.firstIndex(where: { $0.id == id }) else {
            startNewMSegment(firstToken: token, label: speakerLabel)
            return
        }

        if let lockedLang = segments[index].lang,
           (speakerLabel != segments[index].speaker || token.language != lockedLang) {
            // A final token changed speaker or language from the open
            // segment's locked values: cut a new segment rather than
            // silently relabelling the one already on screen.
            closeSegment(id: id)
            isCurrentMSegmentOpen = false
            startNewMSegment(firstToken: token, label: speakerLabel)
            return
        }

        appendMOriginalFinal(token, to: id, at: index, label: speakerLabel)
    }

    private func startNewMSegment(firstToken token: SonioxToken, label: String?) {
        // The chunk that is about to close: per SDK ordering (original
        // chunk, then its own translation chunk), by the time a genuinely
        // new segment starts, any M-direct translation for the previous
        // one should already have arrived. If it never did and the
        // previous segment isn't `me` (so it was never going through
        // on-device translation instead), M is not going to send one -
        // stop the "Đang dịch…" placeholder rather than leave it hanging
        // forever.
        if let previousId = currentMSegmentId, let previousIndex = segments.firstIndex(where: { $0.id == previousId }) {
            let previous = segments[previousIndex]
            if previous.isFinal, previous.target == nil, previous.lang != meLanguage {
                segments[previousIndex].targetAbandoned = true
            }
        }

        let id = nextId
        nextId += 1
        currentMSegmentId = id
        isCurrentMSegmentOpen = true
        let initialFinalText = token.isFinal ? token.text : ""
        finalSourceById[id] = initialFinalText
        segments.append(
            Segment(
                id: id,
                speaker: label,
                lang: token.isFinal ? token.language : nil,
                source: initialFinalText,
                target: nil,
                isFinal: false,
                startedAt: TimeInterval(token.startMs ?? 0) / 1000,
                overlap: false
            )
        )
    }

    private func appendMOriginalFinal(_ token: SonioxToken, to id: Int, at index: Int, label: String?) {
        finalSourceById[id, default: ""] += token.text
        segments[index].source = finalSourceById[id] ?? ""
        if segments[index].lang == nil {
            segments[index].lang = token.language
        }
    }

    private func closeSegment(id: Int) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].isFinal = true
        // A closed segment must show only its locked final text - never a
        // non-final tail left over from whichever response last updated it
        // (see `applyStreamM`'s end-of-response recompute, which only ever
        // touches the CURRENTLY open segment). Without this, a segment cut
        // by a speaker/language change or a reconnect - not by its own
        // `<end>` - can freeze mid-word with a partial tail baked in as if
        // it were final.
        let finalText = finalSourceById[id] ?? ""
        segments[index].source = finalText
        guard segments[index].lang == meLanguage else { return }
        guard !finalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        onMeSegmentFinalized?(id, finalText)
    }

    private func applyMTranslation(_ token: SonioxToken) {
        guard let id = currentMSegmentId, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        // M's own translation (target_language = me) is only meaningful for
        // a segment not already in `me` - a me-language segment's M
        // translation is a same-language echo, discarded per
        // docs/soniox-routing.md.
        guard let lang = segments[index].lang, lang != meLanguage else { return }
        // Any translation token at all - final or not - is the real
        // "translation is under way" signal; only a final one is ever
        // committed to `target` (no karaoke reveal of partial translation
        // text, per HANDOFF section 6).
        segments[index].translationInProgress = true
        guard token.isFinal else { return }
        segments[index].target = (segments[index].target ?? "") + token.text
    }

    // MARK: - On-device me -> target translation lifecycle
    //
    // These three are the only way anything outside this file ever mutates
    // a `me`-language segment's `target`/`translationInProgress`/
    // `targetAbandoned` - called by `SonioxLiveSession` as it drains the
    // narrow translation-queue interface documented in
    // docs/soniox-routing.md, never by `ConversationView` directly. Kept
    // here (rather than mutating `segments` from outside) so this engine
    // stays the single writer of the array, the same guarantee `segments`
    // already has for everything M reports.

    /// The instant the consuming closure actually starts translating
    /// `segmentId` - not when it was merely queued (the outcome's
    /// fatalError rule 7 / AGENTS.md's activity-indicator invariant).
    func applyTranslationStarted(segmentId: Int) {
        guard let index = segments.firstIndex(where: { $0.id == segmentId }) else { return }
        let segment = segments[index]
        guard segment.lang == meLanguage, segment.target == nil, !segment.targetAbandoned else { return }
        segments[index].translationInProgress = true
    }

    /// Writes the whole translated text once - no partial/karaoke reveal,
    /// since Apple's `translate` call is not incremental.
    func applyTranslationSuccess(segmentId: Int, target: String) {
        guard let index = segments.firstIndex(where: { $0.id == segmentId }) else { return }
        segments[index].target = target
        segments[index].translationInProgress = false
    }

    /// An error, or the queue/stream being abandoned outright (session end,
    /// the view disappearing, the task being cancelled) - either way this
    /// is permanent: never retried automatically, per the outcome's
    /// fatalError rule 8.
    func applyTranslationFailure(segmentId: Int) {
        guard let index = segments.firstIndex(where: { $0.id == segmentId }) else { return }
        segments[index].targetAbandoned = true
        segments[index].translationInProgress = false
    }
}
