import Foundation

/// The narrow interface between `SonioxLiveSession` and the untested Apple
/// Translation adapter living in `ConversationView`'s `.translationTask`
/// closure (see docs/soniox-routing.md and the outcome's fatalError rules):
/// a FIFO stream of final `me`-language segments waiting to be translated
/// vi -> en, one at a time, with lifecycle events reported back by request
/// id. `TranslationSession` never appears here - only `(id, source)` pairs
/// and plain result callbacks - which is what lets this be driven by a fake
/// in `SermivaTests` standing in for the closure, and lets a different
/// per-segment engine replace Apple later by only changing that closure.
///
/// Deliberately not `@MainActor`: `SonioxLiveSession` (a `@MainActor` type)
/// constructs one eagerly as a stored property default from its own
/// `nonisolated init` - see that initializer's doc comment. Every method
/// here is only ever actually called from the main actor in practice (by
/// `SonioxLiveSession` and, indirectly, `ConversationView`'s
/// `.translationTask` closure); `onTermination` is the one callback that
/// can fire on an arbitrary executor, so it hops back explicitly before
/// touching `pendingIds`.
final class MeTranslationQueue {
    private var continuation: AsyncStream<(id: Int, source: String)>.Continuation?
    /// Holds any request enqueued before `makeRequests()` has ever been
    /// called (or between "Phiên mới" and the closure's next loop
    /// iteration reaching `makeTranslationRequests()` again in a re-run) -
    /// replayed the moment a continuation becomes available, so an early
    /// enqueue is never silently lost.
    private var bufferedBeforeStream: [(id: Int, source: String)] = []
    /// Every request currently queued (buffered or yielded but not yet
    /// started) or in-flight (started, not yet reported finished) - the set
    /// `abandonAll` and stream termination both drain.
    private var pendingIds: Set<Int> = []

    /// Every catch inside the consuming closure, and the stream's own
    /// `onTermination` (the view disappearing, or the task cancelled),
    /// abandon queued/in-flight ids the same way - see `abandonAll` and
    /// `makeRequests`'s own wiring below.
    var onAbandoned: ((Int) -> Void)?

    /// A fresh stream every call, per the outcome's fatalError rule 4 - a
    /// re-run of the consuming closure must never double-consume a stream
    /// still wired to a previous run.
    func makeRequests() -> AsyncStream<(id: Int, source: String)> {
        AsyncStream { continuation in
            self.continuation = continuation
            let buffered = bufferedBeforeStream
            bufferedBeforeStream.removeAll()
            buffered.forEach { continuation.yield($0) }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.abandonPending() }
            }
        }
    }

    /// Enqueues one final `me` segment for translation - never a blank or
    /// whitespace-only source (the outcome's fatalError rule 8).
    func enqueue(id: Int, source: String) {
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pendingIds.insert(id)
        if let continuation {
            continuation.yield((id, source))
        } else {
            bufferedBeforeStream.append((id, source))
        }
    }

    /// Retires `id` from tracking on success or failure alike - an error
    /// means "no translation", never a retry (fatalError rule 8).
    func finished(id: Int) {
        pendingIds.remove(id)
    }

    /// Called by `SonioxLiveSession` when the whole session ends - unlike
    /// stream termination, this must NOT finish the underlying continuation:
    /// `.translationTask`'s closure and its stream live for the whole
    /// conversation (fatalError rule 3), across "Phiên mới", so the same
    /// stream must keep accepting requests for the next session.
    func abandonAll() {
        abandonPending()
    }

    private func abandonPending() {
        let ids = pendingIds
        pendingIds.removeAll()
        bufferedBeforeStream.removeAll()
        ids.forEach { onAbandoned?($0) }
    }
}
