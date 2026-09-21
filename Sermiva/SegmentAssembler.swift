import Foundation

/// Pure segment-assembly rules from HANDOFF.md section 6. No timing, no I/O,
/// so this can be covered by fixtures without a scheduler or a fake clock.
enum SegmentAssembler {
    /// Applies a partial or final event. A partial updates `source` in place
    /// by `id`. A final locks `source` and sets `isFinal`, but never writes
    /// `target` itself - `target` only arrives through `fillTarget`, so a
    /// final segment is briefly final with `target == nil` ("Dang dich...").
    /// `speaker`, `lang` and `overlap` are read only when the id is new;
    /// later events for the same id cannot change them.
    static func apply(_ event: DemoEvent, elapsed: TimeInterval, to segments: inout [Segment]) {
        if let index = segments.firstIndex(where: { $0.id == event.id }) {
            segments[index].source = event.src
            if event.type == .final {
                segments[index].isFinal = true
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
                    overlap: event.overlap ?? false
                )
            )
        }
    }

    /// Fills `target` for an already-final segment. A no-op if the segment
    /// is missing or already has a target, so a stray replay can't clobber it.
    static func fillTarget(id: Int, target: String, in segments: inout [Segment]) {
        guard let index = segments.firstIndex(where: { $0.id == id }), segments[index].target == nil else {
            return
        }
        segments[index].target = target
    }
}
