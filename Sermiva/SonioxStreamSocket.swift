import Foundation
import os

/// The thin WebSocket adapter for one Soniox stream, per
/// docs/soniox-routing.md's "Stream contract" section. Deliberately dumb:
/// it sends bytes and control frames, decodes whatever comes back, and maps
/// it onto `SonioxSocketEvent` - including classifying 401/402/403 as
/// `.authRejected` rather than a plain `.response`, so everything upstream
/// of this adapter (`SonioxLiveSession`'s reconnect/retry policy) reacts to
/// app-level lifecycle events, never Soniox's own error-code shape
/// directly. All the join and segment logic lives in `SonioxJoinEngine`,
/// which never sees this type either. AGENTS.md forbids testing through
/// this adapter, since Soniox's exact stream shape is unconfirmed; nothing
/// in `SermivaTests` references this file - see `SonioxSocketConnecting`
/// for the seam that is tested instead.
///
/// `URLSessionWebSocketTask`'s completion and receive handlers are not
/// guaranteed to run on the main actor, so every one of them hops back with
/// `Task { @MainActor in ... }` before touching `onEvent` or any other
/// actor-isolated state.
@MainActor
final class SonioxStreamSocket: NSObject, SonioxSocketConnecting {
    var onEvent: ((SonioxSocketEvent) -> Void)?

    private static let endpoint = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!

    /// Set by `SonioxLiveSession.connectFresh` right after creating this
    /// socket (`setLogLabels`), purely to label log lines - always "M" in
    /// option C's single-socket design, and the id of the
    /// `SonioxLiveSession` that owns this socket. `nonisolated(unsafe)` so
    /// `close()`, the delegate callbacks and `deinit` (all nonisolated) can
    /// include them; set once, right after creation, before `connect()`,
    /// never mutated afterward.
    nonisolated(unsafe) private(set) var streamLabel: String = "?"
    nonisolated(unsafe) private(set) var ownerSessionId = 0

    func setLogLabels(streamLabel: String, sessionId: Int) {
        self.streamLabel = streamLabel
        ownerSessionId = sessionId
    }

    /// Every lifecycle line starts with the owning session's id and this
    /// socket's own id, so one Console filter can tell whether two lines
    /// came from one object or two, and from one session or two.
    nonisolated private var logPrefix: String {
        "session #\(ownerSessionId) socket #\(socketId) [\(streamLabel)]"
    }

    /// A unique id for THIS socket object (each object is used for exactly
    /// one connection attempt). The live evidence from 8846c89 (every
    /// `SonioxTranslationStatusShape` line printed twice, <1 ms apart, right
    /// after a reconnect) has no established cause: two socket objects each
    /// logging once, and one line duplicated after it was logged, look the
    /// same without an id. With it, the owner's next live session can tell
    /// the two apart directly in the Console - see docs/soniox-routing.md.
    let socketId = LifecycleIds.socket.next()

    /// The REAL count of sockets whose underlying task has not yet reported
    /// completion - incremented when a task is created (`connect()`, on the
    /// main actor) and decremented ONLY by `urlSession(_:task:didCompleteWithError:)`
    /// below (the delegate's own authoritative "this task is actually done"
    /// signal, nonisolated - URLSession does not guarantee which queue it
    /// runs on). Review round 5, finding A (owner instruction): the
    /// previous round counted from `close()` instead, which only proves the
    /// app ASKED to close a socket, never that the underlying task actually
    /// stopped - exactly the gap a reviewer identified in the two-socket
    /// investigation. `NSLock`-guarded rather than a bare
    /// `nonisolated(unsafe)` var, since this is now genuinely written from
    /// two execution contexts with no actor serializing them against each
    /// other (the main actor and URLSession's own delegate queue).
    // `NSLock` is itself `Sendable` and immutable here, so `nonisolated`
    // alone (no `unsafe`) is enough to make this STATIC member (unlike an
    // instance member, static members of a `@MainActor` type default to
    // main-actor isolation regardless of their value's own Sendability)
    // reachable from the nonisolated delegate callback below.
    nonisolated private static let openTaskCountLock = NSLock()
    nonisolated(unsafe) private static var openTaskCount = 0

    @discardableResult
    nonisolated private static func adjustOpenTaskCount(by delta: Int) -> Int {
        openTaskCountLock.lock()
        defer { openTaskCountLock.unlock() }
        openTaskCount += delta
        return openTaskCount
    }

    /// docs/soniox-routing.md's Unknowns table: `translation_status` has
    /// never been read directly off the wire - `"none"` is inferred from
    /// the docs' two-way example and an observed symptom, not confirmed.
    /// This records only the shape - the set of distinct raw strings seen,
    /// and which one a marker (`<end>`/`<fin>`) carried - never token text,
    /// the key, or a URL. One log line per newly-seen distinct value, plus
    /// one per marker occurrence (both low-volume by construction), so a
    /// live session's Console log settles into a short, readable summary
    /// rather than one line per token.
    private static let diagnosticLogger = Logger(subsystem: "com.clongnguyen6.sermiva", category: "SonioxTranslationStatusShape")
    private var seenTranslationStatusValues: Set<String> = []

    private func recordTranslationStatusShape(_ wire: SonioxTokenWire) {
        let raw = wire.translationStatus ?? "<missing>"
        let label = streamLabel
        if !seenTranslationStatusValues.contains(raw) {
            seenTranslationStatusValues.insert(raw)
            Self.diagnosticLogger.log("\(self.logPrefix, privacy: .public) stream \(label, privacy: .public) saw a new translation_status value: \(raw, privacy: .public)")
        }
        if wire.text == "<end>" || wire.text == "<fin>" {
            Self.diagnosticLogger.log("\(self.logPrefix, privacy: .public) stream \(label, privacy: .public) marker \(wire.text, privacy: .public) carried translation_status: \(raw, privacy: .public)")
        }
    }

    /// Created in `connect()` and invalidated in `close()`. A `URLSession`
    /// keeps a STRONG reference to its delegate (`self`) until it is
    /// invalidated - round 5 created one per socket with `delegate: self` and
    /// never invalidated it, so every socket object, and its session, stayed
    /// alive for the life of the process (review of 54b3202, finding 5).
    /// `nonisolated(unsafe)` for the same reason as `task` below.
    nonisolated(unsafe) private var urlSession: URLSession?
    /// `nonisolated(unsafe)` so `close()` can run from a nonisolated
    /// context - specifically `SonioxLiveSession.deinit`, which needs to
    /// guarantee this socket's underlying task is cancelled even when
    /// nothing else ever calls `close()`. `URLSessionWebSocketTask.cancel`
    /// itself is documented thread-safe; every other access to `task`
    /// still only ever happens from this class's own MainActor-isolated
    /// methods.
    nonisolated(unsafe) private var task: URLSessionWebSocketTask?

    deinit {
        lifecycleLogger.log("\(self.logPrefix, privacy: .public) object deinit")
    }

    func connect(apiKey: String, languageHints: [String], targetLanguage: String) {
        let config = SonioxStreamConfig(apiKey: apiKey, languageHints: languageHints, translation: .init(targetLanguage: targetLanguage))
        // `self` is this session's delegate (see `URLSessionTaskDelegate`
        // below), so it cannot be built before `super.init()`; one session
        // per socket object, which is used for exactly one connection.
        let urlSession = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.urlSession = urlSession
        let task = urlSession.webSocketTask(with: Self.endpoint)
        self.task = task
        let openNow = Self.adjustOpenTaskCount(by: 1)
        lifecycleLogger.log("\(self.logPrefix, privacy: .public) task created (connect attempt) - \(openNow, privacy: .public) real tasks open now")
        task.resume()
        guard let configData = try? JSONEncoder().encode(config), let configText = String(data: configData, encoding: .utf8) else {
            onEvent?(.closed(nil))
            return
        }
        task.send(.string(configText)) { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.onEvent?(.closed(error))
                    return
                }
                self.onEvent?(.configSent)
                self.receiveNext()
            }
        }
    }

    func sendAudio(_ data: Data) {
        task?.send(.data(data)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.onEvent?(.closed(error)) }
        }
    }

    func sendKeepalive() {
        sendControlFrame(type: "keepalive")
    }

    func sendFinalize() {
        sendControlFrame(type: "finalize")
    }

    /// Ends the stream per the docs' end-of-stream sequence: an empty frame
    /// after `finalize`, then close once `finished` arrives or a timeout
    /// passes - the timeout itself is `LiveSessionController`'s job, since
    /// it is a session-lifecycle policy, not a socket concern.
    func sendEmptyFrame() {
        task?.send(.data(Data())) { _ in }
    }

    /// `nonisolated` so this can also be called from
    /// `SonioxLiveSession.deinit` (a nonisolated context) - see `task`.
    /// Review round 4, finding 1: `cancel(with:reason:)` alone is the
    /// WebSocket-specific graceful close (a close frame per RFC 6455), and
    /// is not documented to reliably abort a task that has not yet finished
    /// its HTTP-upgrade handshake - exactly the moment a reconnect is most
    /// likely to call `close()` on the socket it is abandoning. The plain
    /// `URLSessionTask.cancel()` unconditionally tears the task down at the
    /// URLSession level regardless of handshake state, so both are called
    /// now - calling cancel twice on the same task is documented safe.
    /// Guarded on `task != nil` so a second `close()` call (this app's own
    /// `handleDrop`/`end` sequence, plus `deinit`'s own belt-and-suspenders
    /// call, can both reach the same socket) never double-logs this line.
    /// Review round 5, finding A (owner instruction): this deliberately
    /// does NOT touch the real open-task count any more - it only proves
    /// the app ASKED the task to stop, never that it actually did. Compare
    /// this line's socket id, live, against the "task ACTUALLY completed"
    /// line the `URLSessionTaskDelegate` callback below logs - a gap or
    /// mismatch between the two is exactly what would confirm or rule out
    /// this cancel-reliability theory.
    /// `finishTasksAndInvalidate()` then lets the just-cancelled task report
    /// its completion to the delegate (that "ACTUALLY completed" line) and
    /// only afterwards invalidates the session, which is what releases its
    /// strong reference to `self` - see `urlSession`. It is documented safe
    /// from any thread, like `cancel`.
    nonisolated func close() {
        guard task != nil else { return }
        task?.cancel(with: .normalClosure, reason: nil)
        task?.cancel()
        task = nil
        urlSession?.finishTasksAndInvalidate()
        urlSession = nil
        lifecycleLogger.log("\(self.logPrefix, privacy: .public) close() called by the app")
    }

    private func sendControlFrame(type: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": type]), let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor in self?.onEvent?(.closed(error)) }
        }
    }

    private func receiveNext() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    self.onEvent?(.closed(error))
                case .success(let message):
                    self.handle(message)
                    self.receiveNext()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data?
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: data = nil
        }
        guard let data, let response = try? JSONDecoder().decode(SonioxStreamResponse.self, from: data) else { return }
        // 401/402/403 are the docs' auth-class errors; 400 is not, and
        // must not be treated as one. Classified here, in the adapter, so
        // everything upstream reacts to the app-level `.authRejected`
        // event rather than inspecting Soniox's own error-code shape.
        if let code = response.errorCode, (401...403).contains(code) {
            onEvent?(.authRejected)
            return
        }
        for wireToken in response.tokens ?? [] {
            recordTranslationStatusShape(wireToken)
        }
        // Mapped from the wire tokens to the app's own `SonioxToken` here,
        // in the adapter, so nothing downstream of this seam ever touches
        // `SonioxTokenWire`/`SonioxStreamResponse` either.
        let tokens = (response.tokens ?? []).map { $0.appToken }
        onEvent?(.response(SonioxSocketResponse(tokens: tokens, finalAudioProcMs: response.finalAudioProcMs ?? 0)))
    }
}

extension SonioxStreamSocket: URLSessionTaskDelegate {
    /// The delegate's own authoritative "this task is actually done" signal
    /// - review round 5, finding A (owner instruction): count real open
    /// connections from here, never from `close()` (see its own doc
    /// comment). Not guaranteed to run on the main actor (URLSession does
    /// not document which queue calls this), so `nonisolated` - only touches
    /// `socketId`/`streamLabel` (already safe from any context) and the
    /// lock-guarded static counter.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let openNow = Self.adjustOpenTaskCount(by: -1)
        lifecycleLogger.log("\(self.logPrefix, privacy: .public) task ACTUALLY completed - \(openNow, privacy: .public) real tasks open now")
    }

    /// The session let go of its delegate - after this, nothing but
    /// `SonioxLiveSession` (which dropped it already) keeps this socket
    /// object alive, so its "object deinit" line should follow.
    nonisolated func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        lifecycleLogger.log("\(self.logPrefix, privacy: .public) URLSession invalidated")
    }
}
