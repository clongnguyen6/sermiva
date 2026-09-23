import Foundation

/// Builds `Segment` values from Soniox stream M (translated into `me`), and
/// fills `target` for `me`-language segments using stream T (translated
/// into `target`), through the no-guess join described in
/// `docs/soniox-routing.md`. Pure, app-owned logic: it consumes
/// `SonioxToken` batches, never raw wire JSON or a live socket, so it is
/// testable without the WebSocket adapter - the boundary AGENTS.md and the
/// outcome brief both require.
///
/// Only final tokens drive segment text and committed translation text.
/// The join's certainty checks are the opposite: a non-final original
/// token disqualifies a window exactly like a final one would, checked the
/// instant it is seen, per docs/soniox-routing.md's "T chunks" section -
/// waiting for finality would let a wrong-language non-final original slip
/// through uninspected. Non-final tokens still update the currently open
/// segment's displayed source text in place, the same spirit as
/// `SegmentAssembler`'s partial handling for demo playback.
@MainActor
final class SonioxJoinEngine {
    private(set) var segments: [Segment] = []

    let meLanguage: String

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

    private struct MLogEntry {
        let segmentId: Int
        let startMs: Int
        let endMs: Int
        let speaker: String?
        let language: String
    }

    /// Every final M original token ever seen, tagged with the segment it
    /// belongs to - the record the join's check 2 ("M itself saw no overlap
    /// in the window") scans.
    private var mFinalOriginalLog: [MLogEntry] = []

    private struct PendingJoin {
        let segmentId: Int
        let windowStart: Int
        let windowEnd: Int
        var collectedTarget: String = ""
        var disqualified = false
        var resolved = false
    }

    private var pendingJoins: [Int: PendingJoin] = [:]

    /// One unit of T's stream, in the wire's own order: an original run -
    /// every original/none token, final and non-final alike, until
    /// translation begins - followed by its translation run - every
    /// translation token, final and non-final, until the next original
    /// token (of any finality) or a marker ends it. See
    /// docs/soniox-routing.md's "T chunks" section.
    private struct TChunk {
        var originals: [SonioxToken] = []
        var translations: [SonioxToken] = []
    }

    /// The chunk currently being collected from live T tokens.
    private var currentTChunk = TChunk()

    /// What the chunk currently being collected looks like it is heading
    /// for, tracked live (token by token, before the chunk itself has
    /// completed) purely so the placeholder can reflect a genuine
    /// in-progress signal. Never used to decide where translated text
    /// actually lands - only a completed chunk's own `attemptAttach`
    /// result decides that, using every one of its tokens at once.
    private enum ChunkCandidate: Equatable {
        case unknown
        case window(Int)
        case ambiguous
    }
    private var currentChunkCandidate: ChunkCandidate = .unknown

    /// The window most recently, actually attached to by a completed
    /// chunk - the one still receiving further qualifying chunks'
    /// translated text, and the one that resolves when a later completed
    /// chunk's attribution moves away from it (a different window, no
    /// window, or a marker). Distinct from `currentChunkCandidate`, which
    /// is a live, still-unsettled guess about the chunk in progress.
    private var activeWindowId: Int?

    /// Completed chunks (and whether a marker ended them) whose originals
    /// matched no open window at all when they completed - replayed as
    /// whole units, in original order, once a new window opens (see
    /// docs/soniox-routing.md's "T chunks" section). Capped so a chunk
    /// that will truly never match (e.g. pure guest speech outside any
    /// `me` window) cannot grow this without bound over a long session.
    private var bufferedTChunks: [(chunk: TChunk, endedByMarker: Bool)] = []
    private let bufferedTChunksLimit = 50

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

    /// Either stream reconnecting invalidates the shared time origin the
    /// join depends on (see docs/soniox-routing.md): abandon every T-join
    /// window still in flight rather than let a pre-drop window be
    /// compared against post-drop timestamps that no longer share an
    /// origin with it. Since a reconnect always tears down and reopens M
    /// too, this also abandons any non-`me` segment whose M-direct
    /// translation was already under way but not yet complete - M's old
    /// connection is gone, so nothing is ever coming to finish it, and it
    /// must not keep showing "Đang dịch…" against a connection that no
    /// longer exists.
    func abandonAllPendingJoins() {
        for (id, join) in pendingJoins where !join.resolved {
            var resolved = join
            resolved.resolved = true
            pendingJoins[id] = resolved
            markAbandoned(segmentId: id)
        }
        bufferedTChunks.removeAll()
        currentTChunk = TChunk()
        currentChunkCandidate = .unknown
        activeWindowId = nil

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
        // previous segment isn't `me` (so it was never going through the
        // T-join instead), M is not going to send one - stop the
        // "Đang dịch…" placeholder rather than leave it hanging forever.
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
        if token.isFinal, let startMs = token.startMs, let language = token.language {
            let endMs = token.endMs ?? startMs
            mFinalOriginalLog.append(MLogEntry(segmentId: id, startMs: startMs, endMs: endMs, speaker: label, language: language))
            reevaluatePendingJoins(against: mFinalOriginalLog.last!)
        }
    }

    private func appendMOriginalFinal(_ token: SonioxToken, to id: Int, at index: Int, label: String?) {
        finalSourceById[id, default: ""] += token.text
        segments[index].source = finalSourceById[id] ?? ""
        if segments[index].lang == nil {
            segments[index].lang = token.language
        }
        if let startMs = token.startMs, let language = token.language {
            let endMs = token.endMs ?? startMs
            mFinalOriginalLog.append(MLogEntry(segmentId: id, startMs: startMs, endMs: endMs, speaker: label, language: language))
            reevaluatePendingJoins(against: mFinalOriginalLog.last!)
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
        segments[index].source = finalSourceById[id] ?? ""
        guard segments[index].lang == meLanguage, let lastEntry = mFinalOriginalLog.last(where: { $0.segmentId == id }) else {
            return
        }
        let windowStart = Int(segments[index].startedAt * 1000)
        let windowEnd = max(lastEntry.endMs, windowStart)
        pendingJoins[id] = PendingJoin(segmentId: id, windowStart: windowStart, windowEnd: windowEnd)
        replayBufferedTChunks(newWindowStart: windowStart)
        recheckCurrentTChunkAgainstOpenWindows()
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

    // MARK: - Stream T (join only - T's own original text is never shown)
    //
    // Modelled explicitly as a sequence of chunks - see docs/soniox-routing.md's
    // "T chunks" section, which this code must match line by line. An
    // original run (every `.original`/`.none` token, final and non-final)
    // followed by its translation run (every `.translation` token, final
    // and non-final), ending the instant another original arrives (any
    // finality) or a marker does. Attribution - which window, if any, a
    // completed chunk's translated text belongs to - is decided once, using
    // every one of the chunk's original tokens at once (`attemptAttach`),
    // never per raw token and never by finality. Check 1 (wrong-language
    // disqualification) is separate and immediate, live, per original
    // token, the instant it is seen - not deferred to chunk completion.

    func applyStreamT(_ tokens: [SonioxToken]) {
        var sawTranslationTokenThisResponse = false
        for token in tokens {
            if isEndMarker(token) {
                finishCurrentTChunk(endedByMarker: true)
                continue
            }
            switch token.translationStatus {
            case .original, .none:
                // `.none` on stream T (target_language = target) is speech
                // already in `target` - still a real original token for
                // check 1: e.g. the guest speaking target while the owner
                // speaks `me` must still disqualify the window, exactly as
                // an `.original` token would.
                if !currentTChunk.translations.isEmpty {
                    // The translation run for the current chunk has ended -
                    // this original token, whatever its own finality,
                    // starts the next chunk.
                    finishCurrentTChunk(endedByMarker: false)
                }
                checkOriginalAgainstOpenWindow(token)
                noteOriginalForCandidate(token)
                currentTChunk.originals.append(token)
            case .translation:
                currentTChunk.translations.append(token)
                if case .window(let id) = currentChunkCandidate,
                   let join = pendingJoins[id], !join.disqualified, !join.resolved {
                    // Any translation token at all - final or not - is the
                    // real "translation is under way" signal for the
                    // window this chunk currently looks like it belongs
                    // to; only final ones are ever committed to text (no
                    // karaoke reveal), decided later at chunk completion.
                    sawTranslationTokenThisResponse = true
                    markTranslationInProgress(segmentId: id)
                }
            case .unrecognized:
                continue
            }
        }
        clearStaleTTranslationSignal(sawTranslationTokenThisResponse: sawTranslationTokenThisResponse)
    }

    private func findOpenCandidate(forStartMs startMs: Int) -> (id: Int, join: PendingJoin)? {
        guard let match = pendingJoins.first(where: { _, join in !join.resolved && startMs >= join.windowStart && startMs <= join.windowEnd }) else {
            return nil
        }
        return (id: match.key, join: match.value)
    }

    /// Check 1: a non-me original token inside a window - final or not -
    /// fails that window's join permanently, the instant it is seen. E.g.
    /// the guest speaking target while the owner also speaks `me` in the
    /// same window. Independent of chunk boundaries entirely: this is a
    /// property of the window (did ANY T original token's timestamp and
    /// language violate it), not of which chunk that token happens to
    /// belong to.
    private func checkOriginalAgainstOpenWindow(_ token: SonioxToken) {
        guard let startMs = token.startMs, let match = findOpenCandidate(forStartMs: startMs) else { return }
        guard var join = pendingJoins[match.id], !join.disqualified else { return }
        guard token.language != meLanguage else { return }
        join.disqualified = true
        pendingJoins[match.id] = join
        markAbandoned(segmentId: join.segmentId)
    }

    /// Live, incremental tracking of which single window the chunk in
    /// progress currently looks like it belongs to - for the placeholder
    /// only (see `currentChunkCandidate`'s own doc comment). A token that
    /// matches nothing does not contradict the existing candidate (M may
    /// simply not have opened that window yet); a token that matches a
    /// DIFFERENT window than the existing candidate makes it ambiguous
    /// (straddle) for the rest of this chunk.
    private func noteOriginalForCandidate(_ token: SonioxToken) {
        guard let startMs = token.startMs, let match = findOpenCandidate(forStartMs: startMs),
              let join = pendingJoins[match.id], !join.disqualified else { return }
        switch currentChunkCandidate {
        case .unknown:
            currentChunkCandidate = .window(match.id)
        case .window(let existing) where existing != match.id:
            currentChunkCandidate = .ambiguous
        case .window, .ambiguous:
            break
        }
    }

    private enum TChunkAttachOutcome {
        case attached(windowId: Int, translatedText: String)
        /// The single window this chunk's originals all pointed to is
        /// already disqualified, or its originals span more than one
        /// window (a straddle) - attaching to either would be a guess
        /// about which part of the chunk belongs there.
        case discarded
        /// None of the chunk's originals matched any currently open
        /// window - an "early chunk", buffered for replay.
        case noWindowYet
    }

    /// Decides attribution for one COMPLETE chunk, using every one of its
    /// original tokens, final and non-final alike - never just the last
    /// one seen, and never per raw token. A chunk attaches only when EVERY
    /// original token in it falls inside the bounds of the SAME single
    /// still-open, not-yet-disqualified window - an original token that
    /// matches no open window at all (not just a different one) also fails
    /// this, exactly like a straddle across two windows: attaching on the
    /// strength of only the tokens that happen to match would be guessing
    /// about the ones that do not.
    private func attemptAttach(_ chunk: TChunk) -> TChunkAttachOutcome {
        var matchedIds = Set<Int>()
        var sawUnmatchedOriginal = false
        for original in chunk.originals {
            guard let startMs = original.startMs, let match = findOpenCandidate(forStartMs: startMs) else {
                sawUnmatchedOriginal = true
                continue
            }
            matchedIds.insert(match.id)
        }
        guard matchedIds.count == 1, let windowId = matchedIds.first else {
            return matchedIds.isEmpty ? .noWindowYet : .discarded
        }
        guard !sawUnmatchedOriginal else {
            return .discarded
        }
        guard let join = pendingJoins[windowId], !join.disqualified else {
            return .discarded
        }
        let translatedText = chunk.translations.filter(\.isFinal).map(\.text).joined()
        return .attached(windowId: windowId, translatedText: translatedText)
    }

    /// The chunk that was just live-tracked as `currentChunkCandidate` has,
    /// by definition, stopped being "currently mid-way through translating"
    /// the instant it completes - regardless of whether a later chunk in
    /// the SAME response goes on to target the same window again (which
    /// re-sets the signal true via `markTranslationInProgress` once that
    /// later chunk's own translation tokens actually arrive) or a
    /// different one. Without this, a window whose only live-tracked chunk
    /// already finished this response keeps showing "Đang dịch…" simply
    /// because `clearStaleTTranslationSignal`'s response-wide check only
    /// ever looks at whichever window the NEW chunk is heading for.
    private func finishCurrentTChunk(endedByMarker: Bool) {
        let chunk = currentTChunk
        currentTChunk = TChunk()
        if case .window(let id) = currentChunkCandidate {
            clearInProgressForCompletedChunk(segmentId: id)
        }
        currentChunkCandidate = .unknown
        attachOrBuffer(chunk, endedByMarker: endedByMarker)
    }

    private func clearInProgressForCompletedChunk(segmentId: Int) {
        guard let index = segments.firstIndex(where: { $0.id == segmentId }) else { return }
        let segment = segments[index]
        guard segment.translationInProgress, segment.target == nil, !segment.targetAbandoned else { return }
        segments[index].translationInProgress = false
    }

    /// Attaches a chunk to whichever window it qualifies for (accumulating
    /// onto that window's collected translation - a window commonly
    /// receives more than one chunk, since T often segments the same M
    /// window's audio more finely than M does), resolving whichever window
    /// was previously active the moment chunk activity moves away from it -
    /// see docs/soniox-routing.md's "Complete" rule. Buffers a chunk that
    /// matches no window yet. Shared by live processing and by replaying
    /// buffered early chunks, so both go through exactly the same decision.
    private func attachOrBuffer(_ chunk: TChunk, endedByMarker: Bool) {
        guard !chunk.originals.isEmpty || !chunk.translations.isEmpty else {
            if endedByMarker, let id = activeWindowId {
                resolveJoin(id: id)
                activeWindowId = nil
            }
            return
        }
        switch attemptAttach(chunk) {
        case .attached(let windowId, let translatedText):
            if activeWindowId != windowId {
                if let previous = activeWindowId { resolveJoin(id: previous) }
                activeWindowId = windowId
            }
            if !translatedText.isEmpty, var join = pendingJoins[windowId] {
                join.collectedTarget += translatedText
                pendingJoins[windowId] = join
            }
            if endedByMarker {
                resolveJoin(id: windowId)
                activeWindowId = nil
            }
        case .discarded:
            if let previous = activeWindowId { resolveJoin(id: previous) }
            activeWindowId = nil
        case .noWindowYet:
            // Unlike `.discarded`, this chunk was never actually checked
            // against any real, currently open window at all - it is
            // genuinely undecided, not "resolved to elsewhere" (see
            // docs/soniox-routing.md: "a chunk that still matches nothing
            // is buffered again"). Whatever window was previously active
            // stays exactly as active/pending as before; only a chunk that
            // is actually decided against real windows (`.attached` to a
            // different one, or `.discarded`) is a genuine "moved on"
            // signal for it.
            bufferedTChunks.append((chunk: chunk, endedByMarker: endedByMarker))
            if bufferedTChunks.count > bufferedTChunksLimit {
                bufferedTChunks.removeFirst(bufferedTChunks.count - bufferedTChunksLimit)
            }
        }
    }

    /// Replays every buffered early chunk - as whole units, including
    /// whichever one carried a marker - against the pending joins now that
    /// a new window (starting at `newWindowStart`) has just opened, in
    /// original arrival order. A chunk that still matches nothing lands
    /// back in the buffer via the same path; afterwards, any buffered
    /// chunk whose last original token is now provably in the past (before
    /// the earliest window that could ever exist) is dropped for good,
    /// since M only opens windows in increasing chronological order.
    ///
    /// Check 1 (the language check) is re-run against every one of a
    /// buffered chunk's original tokens here, before `attemptAttach` - when
    /// each token first arrived live, `checkOriginalAgainstOpenWindow` had
    /// no window yet to check it against (that is exactly what made the
    /// chunk "early"), so a wrong-language buffered chunk must not attach
    /// on timing alone just because a window matching its timestamps
    /// happens to open later - see docs/soniox-routing.md's "T chunks".
    private func replayBufferedTChunks(newWindowStart: Int) {
        let snapshot = bufferedTChunks
        bufferedTChunks = []
        for (chunk, endedByMarker) in snapshot {
            for original in chunk.originals {
                checkOriginalAgainstOpenWindow(original)
            }
            attachOrBuffer(chunk, endedByMarker: endedByMarker)
        }
        bufferedTChunks.removeAll { entry in
            guard let lastStartMs = entry.chunk.originals.last?.startMs else { return false }
            return lastStartMs < newWindowStart
        }
    }

    /// The chunk currently being collected may have started before any
    /// window existed to check it against - `checkOriginalAgainstOpenWindow`
    /// and `noteOriginalForCandidate` only ever run once, when each token
    /// first arrives, so a token that arrived too early never gets a second
    /// look on its own. Re-running both against every one of its original
    /// tokens whenever a new window opens is what lets check 1 still catch
    /// a disqualifying token that arrived before the window it violates
    /// even existed.
    private func recheckCurrentTChunkAgainstOpenWindows() {
        currentChunkCandidate = .unknown
        for original in currentTChunk.originals {
            checkOriginalAgainstOpenWindow(original)
            noteOriginalForCandidate(original)
        }
    }

    /// Non-final tokens are replaced in full on every response
    /// (docs/soniox-routing.md) - so "the latest response still carries a
    /// translation token for the chunk currently heading toward this
    /// window" is itself the live signal, not just its first appearance.
    /// Mirrors `clearStaleMDirectTranslationSignal` exactly.
    private func clearStaleTTranslationSignal(sawTranslationTokenThisResponse: Bool) {
        guard !sawTranslationTokenThisResponse, case .window(let id) = currentChunkCandidate,
              let index = segments.firstIndex(where: { $0.id == id }) else { return }
        let segment = segments[index]
        guard segment.translationInProgress, segment.target == nil else { return }
        segments[index].translationInProgress = false
    }

    private func markAbandoned(segmentId: Int) {
        guard let index = segments.firstIndex(where: { $0.id == segmentId }) else { return }
        segments[index].targetAbandoned = true
    }

    private func markTranslationInProgress(segmentId: Int) {
        guard let index = segments.firstIndex(where: { $0.id == segmentId }) else { return }
        segments[index].translationInProgress = true
    }

    /// Check 2: M itself saw no overlap in the window. Runs against every
    /// still-open pending join whenever a new final M original token is
    /// logged, since overlap can be discovered after the window already
    /// opened (diarization can interleave a second speaker's tokens with
    /// earlier timestamps than tokens already processed).
    private func reevaluatePendingJoins(against entry: MLogEntry) {
        for (id, var join) in pendingJoins where !join.disqualified && !join.resolved && id != entry.segmentId {
            guard entry.startMs >= join.windowStart, entry.startMs <= join.windowEnd else { continue }
            join.disqualified = true
            pendingJoins[id] = join
            markAbandoned(segmentId: id)
        }
    }

    /// Commits or abandons the join for `id`, once a completed T chunk has
    /// actually signalled it is done - see `attachOrBuffer`'s callers:
    /// chunk activity moving to a different window or to none at all, or
    /// T's own `<end>`/`<fin>` - never on `final_audio_proc_ms` catching
    /// up, which lags translation generation and was the source of the
    /// live-observed truncated/missing `me`-translation bug
    /// (docs/soniox-routing.md). `target` fills only if the join was never
    /// disqualified and actually collected something real; otherwise it is
    /// abandoned. Either way `resolved` stops the "Đang dịch…" placeholder
    /// and stops accepting any further T chunks for that window.
    private func resolveJoin(id: Int) {
        guard var join = pendingJoins[id], !join.resolved else { return }
        join.resolved = true
        pendingJoins[id] = join
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        if !join.disqualified, !join.collectedTarget.isEmpty {
            segments[index].target = join.collectedTarget
        } else {
            segments[index].targetAbandoned = true
        }
    }
}
