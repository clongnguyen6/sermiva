import Foundation

/// Pure segment-assembly rules from HANDOFF.md section 6. No timing, no I/O,
/// so this can be covered by fixtures without a scheduler or a fake clock.
enum SegmentAssembler {
    /// Applies a partial or final event. A partial updates `source` in place
    /// by `id`. A final locks `source` and sets `isFinal`, but never writes
    /// `target` itself - `target` only arrives through `fillTarget`, so a
    /// final segment is briefly final with `target == nil` ("Dang dich...").
    /// Once a segment is final, `source` stays locked against any later
    /// event for the same id - a late partial or a duplicate delivery must
    /// not be able to change wording that has already locked.
    /// `speaker`, `lang` and `overlap` are read only when the id is new;
    /// later events for the same id cannot change them.
    static func apply(_ event: DemoEvent, elapsed: TimeInterval, to segments: inout [Segment]) {
        if let index = segments.firstIndex(where: { $0.id == event.id }) {
            if !segments[index].isFinal {
                segments[index].source = event.src
            }
            if event.type == .final {
                segments[index].isFinal = true
                // The fixture guarantees a target will land after its own
                // simulated delay - that scheduled fill is demo's real
                // "translation is under way" signal, the same role a live
                // stream's own translation tokens play for
                // `SonioxJoinEngine` - see `Segment.translationInProgress`.
                segments[index].translationInProgress = true
            }
        } else {
            segments.append(
                Segment(
                    id: event.id,
                    speaker: event.speaker,
                    lang: event.lang,
                    source: event.src,
                    target: nil,
                    isFinal: event.type == .final,
                    startedAt: elapsed,
                    overlap: event.overlap ?? false,
                    translationInProgress: event.type == .final
                )
            )
        }
    }

    /// Fills `target` for an already-final segment. A no-op if the segment
    /// is missing, not yet final, or already has a target, so a stray
    /// replay - or a translation scheduled by a previous session landing
    /// late, after "Phien moi" reused the same id for a fresh partial -
    /// can't clobber wording that either isn't locked yet or was never
    /// meant to receive this target.
    static func fillTarget(id: Int, target: String, in segments: inout [Segment]) {
        guard let index = segments.firstIndex(where: { $0.id == id }), segments[index].isFinal, segments[index].target == nil else {
            return
        }
        segments[index].target = target
    }
}
