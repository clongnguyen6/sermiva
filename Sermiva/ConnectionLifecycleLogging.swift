import Foundation
import os

/// Shared plumbing for the connection-lifecycle diagnostics behind review
/// round 4/5's still-unexplained "two live sockets" evidence: every
/// `SonioxStreamSocket`, `SonioxLiveSession`, and `LiveSessionController`
/// instance gets its own small integer id from `LifecycleIds`, logged on
/// creation/destruction and on every connection event. Round 4's per-socket
/// `Set`-based dedup could tell "a new value" from "a repeat" only WITHIN
/// one socket instance - it had no way to tell two genuinely different live
/// socket objects apart from one socket being logged twice, and no way to
/// tell whether more than one `SonioxLiveSession`/`LiveSessionController`
/// existed at once. These ids close that gap for the next live session.
/// One shared `Logger` (not one per type) so the owner can read all of it
/// with a single Console filter. No key, text, or URL in any line.
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
