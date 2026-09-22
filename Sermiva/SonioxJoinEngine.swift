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

    init(meLanguage: String) {
        self.meLanguage = meLanguage
    }

    // MARK: - Stream M

    func applyStreamM(_ tokens: [SonioxToken]) {
        for token in tokens {
            switch token.translationStatus {
            case .original:
                applyMOriginal(token)
            case .translation:
                applyMTranslation(token)
            case .none:
                continue
            }
        }
    }

    private func isEndMarker(_ token: SonioxToken) -> Bool {
        token.text == "<end>" || token.text == "<fin>"
    }

    private func applyMOriginal(_ token: SonioxToken) {
        if isEndMarker(token) {
            if isCurrentMSegmentOpen, let id = currentMSegmentId {
                closeSegment(id: id)
            }
            isCurrentMSegmentOpen = false
            return
        }

        let label = SonioxSpeakerLabel.label(for: token.speaker)

        if !isCurrentMSegmentOpen {
            startNewMSegment(firstToken: token, label: label)
            return
        }

        guard let id = currentMSegmentId, let index = segments.firstIndex(where: { $0.id == id }) else {
            startNewMSegment(firstToken: token, label: label)
            return
        }

        if token.isFinal, let lockedLang = segments[index].lang,
           (label != segments[index].speaker || token.language != lockedLang) {
            // A final token changed speaker or language from the open
            // segment's locked values: cut a new segment rather than
            // silently relabelling the one already on screen.
            closeSegment(id: id)
            isCurrentMSegmentOpen = false
            startNewMSegment(firstToken: token, label: label)
            return
        }

        appendMOriginal(token, to: id, at: index, label: label)
    }

    private func startNewMSegment(firstToken token: SonioxToken, label: String?) {
        let id = nextId
        nextId += 1
        currentMSegmentId = id
        isCurrentMSegmentOpen = true
        segments.append(
            Segment(
                id: id,
                speaker: label,
                lang: token.isFinal ? token.language : nil,
                source: token.text,
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

    private func appendMOriginal(_ token: SonioxToken, to id: Int, at index: Int, label: String?) {
        if token.isFinal {
            segments[index].source += token.text
            if segments[index].lang == nil {
                segments[index].lang = token.language
            }
            if let startMs = token.startMs, let language = token.language {
                let endMs = token.endMs ?? startMs
                mFinalOriginalLog.append(MLogEntry(segmentId: id, startMs: startMs, endMs: endMs, speaker: label, language: language))
                reevaluatePendingJoins(against: mFinalOriginalLog.last!)
            }
        } else {
            // Non-final tokens are replaced in full on every response - the
            // partial tail is provisional display text only.
            segments[index].source = segments[index].source + token.text
        }
    }

    private func closeSegment(id: Int) {
        guard let index = segments.firstIndex(where: { $0.id == id }) else { return }
        segments[index].isFinal = true
        guard segments[index].lang == meLanguage, let lastEntry = mFinalOriginalLog.last(where: { $0.segmentId == id }) else {
            return
        }
        let windowStart = Int(segments[index].startedAt * 1000)
        let join = PendingJoin(segmentId: id, windowStart: windowStart, windowEnd: max(lastEntry.endMs, windowStart))
        pendingJoins[id] = join
        // T's tokens for this window are expected to arrive at, or shortly
        // after, the same wall-clock time as M's - the window only opens
        // once the segment is final, but `resolveJoins` still waits for
        // T's own `final_audio_proc_ms` to actually pass `windowEnd` before
        // giving up, so a T response that is merely running a little behind
        // M is not penalised.
    }

    private func applyMTranslation(_ token: SonioxToken) {
        guard token.isFinal, let id = currentMSegmentId, let index = segments.firstIndex(where: { $0.id == id }) else { return }
        // M's own translation (target_language = me) is only meaningful for
        // a segment not already in `me` - a me-language segment's M
        // translation is a same-language echo, discarded per
        // docs/soniox-routing.md.
        guard let lang = segments[index].lang, lang != meLanguage else { return }
        segments[index].target = (segments[index].target ?? "") + token.text
    }

    // MARK: - Stream T (join only - T's own original text is never shown)

    func applyStreamT(_ tokens: [SonioxToken], finalAudioProcMs: Int) {
        for token in tokens where token.isFinal {
            switch token.translationStatus {
            case .original:
                applyTOriginal(token)
            case .translation:
                applyTTranslation(token)
            case .none:
                continue
            }
        }
        resolveJoins(pastMs: finalAudioProcMs)
    }

    private func applyTOriginal(_ token: SonioxToken) {
        guard let startMs = token.startMs else {
            activeJoinId = nil
            return
        }
        guard let (id, _) = pendingJoins.first(where: { _, join in
            !join.resolved && startMs >= join.windowStart && startMs <= join.windowEnd
        }) else {
            activeJoinId = nil
            return
        }
        guard var join = pendingJoins[id], !join.disqualified else {
            activeJoinId = nil
            return
        }
        if token.language != meLanguage {
            // Check 1: a non-me original token inside the window - e.g. the
            // guest speaking target while the owner also speaks - fails the
            // join permanently. Never guessed past this point.
            join.disqualified = true
            pendingJoins[id] = join
            activeJoinId = nil
            return
        }
        pendingJoins[id] = join
        activeJoinId = id
    }

    private func applyTTranslation(_ token: SonioxToken) {
        guard let id = activeJoinId, var join = pendingJoins[id], !join.disqualified, !join.resolved else { return }
        join.collectedTarget += token.text
        pendingJoins[id] = join
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
