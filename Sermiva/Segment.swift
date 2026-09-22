import Foundation

/// A single utterance in the transcript, per HANDOFF.md section 6.
///
/// `speaker == nil` means diarization has not identified a speaker for this
/// segment; the app must render "Chưa xác định" and must never guess A/B
/// from language. `overlap` is only ever true when the upstream signal said
/// so - it is carried unchanged from the event that created the segment.
struct Segment: Identifiable, Equatable {
    let id: Int
    var speaker: String?
    var lang: String?
    var source: String
    var target: String?
    var isFinal: Bool
    var startedAt: TimeInterval
    var overlap: Bool
    /// Set once the live no-guess join (docs/soniox-routing.md) has given up
    /// on ever filling `target` for this segment - a permanent state, not a
    /// retry. `target == nil` alone means "not yet", which still permits
    /// showing the "Đang dịch…" placeholder; `targetAbandoned` means "never
    /// will", which must not. Demo playback never sets this - it always
    /// eventually fills `target` from the fixture.
    var targetAbandoned: Bool = false
    /// Set once a real translation token - from whichever stream
    /// contributes this segment's translation, final or not - has actually
    /// arrived. `target == nil` alone is not a translation-in-progress
    /// signal; per AGENTS.md's activity-indicator invariant, "Đang dịch…"
    /// must reflect a genuine signal from the service, not merely the
    /// absence of a result yet. Demo playback never sets this - its
    /// placeholder timing comes from the fixture's own simulated delay.
    var translationInProgress: Bool = false
}
