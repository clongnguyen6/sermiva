import Foundation

/// Builds `Segment` values from Soniox stream M (translated into `me`), and
/// fills `target` for `me`-language segments using stream T (translated
/// into `target`), through the no-guess join described in
/// `docs/soniox-routing.md`. Pure, app-owned logic: it consumes
/// `SonioxToken` batches, never raw wire JSON or a live socket, so it is
/// testable without the WebSocket adapter - the boundary AGENTS.md and the
/// outcome brief both require.
///
/// Only final tokens drive segment text, translation text and the join's
/// certainty checks. Non-final ("partial") tokens are provisional and are
/// never allowed to decide a join, per the no-guess rule; they still update
/// the currently open segment's displayed source text in place, the same
/// spirit as `SegmentAssembler`'s partial handling for demo playback.
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
    /// The pending join currently receiving T's translation tokens, i.e.
    /// the join whose qualifying original token was the most recent T
    /// token processed. `nil` whenever the most recent T original token did
    /// not qualify (wrong language, or outside every window) - translation
    /// tokens are only ever attributed to a window whose original token
    /// immediately preceded them, never guessed by proximity alone.
    private var activeJoinId: Int?

    /// T tokens (final, original or translation) that found no matching
    /// pending join when first seen - either because M has not closed that
    /// segment yet, or because nothing matches at all. Replayed whenever a
    /// new pending join opens, so a translation that legitimately arrives
    /// before M's `<end>` is not lost to independent-stream ordering (see
    /// docs/soniox-routing.md). Capped so a token that will truly never
    /// match (e.g. pure guest speech outside any `me` window) cannot grow
    /// this without bound over a long session.
    private var unmatchedTTokens: [SonioxToken] = []
    private let unmatchedTTokensLimit = 200

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
        unmatchedTTokens.removeAll()
        activeJoinId = nil

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

    func applyStreamM(_ tokens: [SonioxToken], finalAudioProcMs: Int = 0) {
        var tailBySegment: [Int: String] = [:]
        for token in tokens {
            switch token.translationStatus {
            case .original:
                applyMOriginal(token, tailBySegment: &tailBySegment)
            case .translation:
                applyMTranslation(token)
            case .none:
                continue
            }
        }
        if isCurrentMSegmentOpen, let id = currentMSegmentId, let index = segments.firstIndex(where: { $0.id == id }) {
            segments[index].source = (finalSourceById[id] ?? "") + (tailBySegment[id] ?? "")
        }
        resolveStalledMDirectTranslations(pastMs: finalAudioProcMs)
    }

    /// A non-`me` segment's M-direct translation can start (a non-final
    /// translation token arrives, docs/soniox-routing.md) and then simply
    /// never finish - `<end>` closes the segment and M moves on without
    /// ever sending a final chunk for it. `final_audio_proc_ms` passing
    /// well beyond that segment's own audio range is the same kind of real
    /// signal `resolveJoins` already trusts for the T-join case: once M's
    /// own processed-audio clock is past that segment's `end_ms`, M is
    /// done with that time range entirely, so nothing further is coming.
    private func resolveStalledMDirectTranslations(pastMs finalAudioProcMs: Int) {
        for index in segments.indices {
            let segment = segments[index]
            guard segment.isFinal, segment.target == nil, segment.translationInProgress,
                  !segment.targetAbandoned, segment.lang != meLanguage else { continue }
            guard let lastEntry = mFinalOriginalLog.last(where: { $0.segmentId == segment.id }) else { continue }
            guard finalAudioProcMs > lastEntry.endMs else { continue }
            segments[index].targetAbandoned = true
        }
    }

    private func isEndMarker(_ token: SonioxToken) -> Bool {
        token.text == "<end>" || token.text == "<fin>"
    }

    private func applyMOriginal(_ token: SonioxToken, tailBySegment: inout [Int: String]) {
        if isEndMarker(token) {
            if isCurrentMSegmentOpen, let id = currentMSegmentId {
                closeSegment(id: id)
            }
            isCurrentMSegmentOpen = false
            return
        }

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
        guard segments[index].lang == meLanguage, let lastEntry = mFinalOriginalLog.last(where: { $0.segmentId == id }) else {
            return
        }
        let windowStart = Int(segments[index].startedAt * 1000)
        let windowEnd = max(lastEntry.endMs, windowStart)
        pendingJoins[id] = PendingJoin(segmentId: id, windowStart: windowStart, windowEnd: windowEnd)
        replayUnmatchedTTokens(newWindowStart: windowStart)
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

    func applyStreamT(_ tokens: [SonioxToken], finalAudioProcMs: Int) {
        for token in tokens {
            switch token.translationStatus {
            case .original:
                if token.isFinal { applyTOriginal(token) }
            case .translation:
                applyTTranslation(token)
            case .none:
                continue
            }
        }
        resolveJoins(pastMs: finalAudioProcMs)
    }

    private func findOpenCandidate(forStartMs startMs: Int) -> (id: Int, join: PendingJoin)? {
        guard let match = pendingJoins.first(where: { _, join in !join.resolved && startMs >= join.windowStart && startMs <= join.windowEnd }) else {
            return nil
        }
        return (id: match.key, join: match.value)
    }

    private func applyTOriginal(_ token: SonioxToken) {
        guard let startMs = token.startMs, let match = findOpenCandidate(forStartMs: startMs) else {
            // No window exists for this timestamp yet - M may simply not
            // have closed the segment yet. Buffer it so a window opening
            // later can still claim it; never guessed in the meantime.
            activeJoinId = nil
            bufferUnmatched(token)
            return
        }
        guard var join = pendingJoins[match.id], !join.disqualified else {
            // A window exists but is already disqualified: permanent, not
            // buffered - replaying it later would not change the verdict.
            activeJoinId = nil
            return
        }
        if token.language != meLanguage {
            // Check 1: a non-me original token inside the window - e.g. the
            // guest speaking target while the owner also speaks - fails the
            // join permanently. Never guessed past this point.
            join.disqualified = true
            pendingJoins[match.id] = join
            markAbandoned(segmentId: join.segmentId)
            activeJoinId = nil
            return
        }
        pendingJoins[match.id] = join
        activeJoinId = match.id
    }

    private func applyTTranslation(_ token: SonioxToken) {
        guard let id = activeJoinId, var join = pendingJoins[id], !join.disqualified, !join.resolved else {
            // No currently-active, still-open window to attach to. Only a
            // final token is buffered for the no-guess replay mechanism
            // (issue 2) - a non-final one is a live signal only, worth
            // nothing to replay later.
            if token.isFinal {
                bufferUnmatched(token)
            }
            return
        }
        // Any translation token at all - final or not - is the real
        // "translation is under way" signal for this window's segment;
        // only a final one is ever committed to `collectedTarget`.
        markTranslationInProgress(segmentId: join.segmentId)
        guard token.isFinal else { return }
        join.collectedTarget += token.text
        pendingJoins[id] = join
    }

    private func bufferUnmatched(_ token: SonioxToken) {
        unmatchedTTokens.append(token)
        if unmatchedTTokens.count > unmatchedTTokensLimit {
            unmatchedTTokens.removeFirst(unmatchedTTokens.count - unmatchedTTokensLimit)
        }
    }

    /// Replays every buffered T token against the pending joins now that a
    /// new window (starting at `newWindowStart`) has just opened, in
    /// original arrival order so `activeJoinId` reconstructs correctly for
    /// an original-then-translation pair. Tokens that still do not match
    /// land back in the buffer via the same `bufferUnmatched` calls above;
    /// afterwards, any buffered original token whose timestamp is now
    /// provably in the past (before the earliest window that could ever
    /// exist) is dropped for good, since M only opens windows in
    /// increasing chronological order.
    private func replayUnmatchedTTokens(newWindowStart: Int) {
        let snapshot = unmatchedTTokens
        unmatchedTTokens = []
        for token in snapshot {
            switch token.translationStatus {
            case .original: applyTOriginal(token)
            case .translation: applyTTranslation(token)
            case .none: continue
            }
        }
        unmatchedTTokens.removeAll { token in
            guard let startMs = token.startMs else { return false }
            return startMs < newWindowStart
        }
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

    /// Closes out any pending join whose window has fully passed T's
    /// processed audio: fills `target` if the join was never disqualified
    /// and something was actually collected, marks it abandoned (never
    /// retried) otherwise. Either way `resolved` stops the "Đang dịch…"
    /// placeholder and stops accepting any further T tokens for that
    /// window.
    private func resolveJoins(pastMs finalAudioProcMs: Int) {
        for (id, join) in pendingJoins where !join.resolved && finalAudioProcMs > join.windowEnd {
            var resolvedJoin = join
            resolvedJoin.resolved = true
            pendingJoins[id] = resolvedJoin
            guard let index = segments.firstIndex(where: { $0.id == id }) else { continue }
            if !join.disqualified, !join.collectedTarget.isEmpty {
                segments[index].target = join.collectedTarget
            } else {
                segments[index].targetAbandoned = true
            }
        }
    }
}
