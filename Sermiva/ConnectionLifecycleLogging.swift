import Foundation
import os

/// Shared plumbing for the connection-lifecycle diagnostics behind the
/// still-unexplained duplicated log lines from 8846c89 (every
/// `SonioxTranslationStatusShape` line printed twice after a reconnect):
/// every `SonioxStreamSocket`, `SonioxLiveSession`, and
/// `LiveSessionController` instance gets its own small integer id from
/// `LifecycleIds`, logged on creation/destruction and on every connection
/// event, and every socket line also carries its owning session's id. The
/// ids only make the hypotheses distinguishable in the Console; they do not
/// establish any of them.
/// Two categories share one subsystem: `SonioxConnectionLifecycle` (this
/// logger) and `SonioxTranslationStatusShape` (`SonioxStreamSocket`'s wire
/// diagnostic). A category filter shows only one of them - filter on
/// `subsystem:com.clongnguyen6.sermiva` to see both, interleaved. No key,
/// text, or URL in any line.
let lifecycleLogger = Logger(subsystem: "com.clongnguyen6.sermiva", category: "SonioxConnectionLifecycle")

/// A tiny thread-safe monotonic counter. Ids are handed out from a
/// `@MainActor` class's `nonisolated init` (`SonioxLiveSession`,
/// `SonioxStreamSocket`) and, for the socket's real task-completion count,
/// from `URLSession`'s own unspecified delegate queue - none of that is
/// already serialized by one actor, so this cannot rely on actor isolation
/// alone the way the rest of this app does.
final class LifecycleIdGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var nextValue = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextValue += 1
        return nextValue
    }
}

enum LifecycleIds {
    static let socket = LifecycleIdGenerator()
    static let session = LifecycleIdGenerator()
    static let controller = LifecycleIdGenerator()
}
