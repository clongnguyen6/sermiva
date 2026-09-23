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
    /// socket, purely to label the one-shot wire-shape diagnostic below -
    /// always "M" in option C's single-socket design. Left at "?" for any
    /// socket nothing ever labels (e.g. a fake in a test, which never
    /// reaches this class at all). `nonisolated(unsafe)` so `close()` (a
    /// nonisolated context - see `task`) can include it in the connection
    /// lifecycle log below; set once, right after creation, never mutated
    /// afterward.
    nonisolated(unsafe) var streamLabel: String = "?"

    /// Review round 4, finding 1 (live evidence): the Console log showed
    /// every `SonioxTranslationStatusShape` line duplicated, <1 ms apart,
    /// right after a reconnect - proof that TWO real `SonioxStreamSocket`
    /// instances were independently connected and receiving the same live
    /// audio at once, with the orphaned one never closed (so the session
    /// was probably billed twice). This logs every socket open/close with a
    /// running total, so a live session's Console log can be scanned for
    /// that total ever exceeding 1 - the app-level generation bookkeeping
    /// alone (`SonioxLiveSession`) cannot prove this from outside a real
    /// network. No key, text, or URL - counts and the M/T-style label only.
    private static let lifecycleLogger = Logger(subsystem: "com.clongnguyen6.sermiva", category: "SonioxConnectionLifecycle")
    /// `nonisolated(unsafe)`: mutated from both `connect()` (MainActor) and
    /// `close()` (nonisolated, reachable from `deinit`) - matches `task`'s
    /// own reasoning. In practice every real call site in this app runs on
    /// the main actor; nothing here claims otherwise for `deinit`, which is
    /// why this is a plain running total, not a strict correctness-critical
    /// value - it is a diagnostic aid, not billing logic.
    nonisolated(unsafe) private static var openConnectionCount = 0

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
            Self.diagnosticLogger.log("stream \(label, privacy: .public) saw a new translation_status value: \(raw, privacy: .public)")
        }
        if wire.text == "<end>" || wire.text == "<fin>" {
            Self.diagnosticLogger.log("stream \(label, privacy: .public) marker \(wire.text, privacy: .public) carried translation_status: \(raw, privacy: .public)")
        }
    }

    private let urlSession: URLSession
    /// `nonisolated(unsafe)` so `close()` can run from a nonisolated
    /// context - specifically `SonioxLiveSession.deinit`, which needs to
    /// guarantee this socket's underlying task is cancelled even when
    /// nothing else ever calls `close()`. `URLSessionWebSocketTask.cancel`
    /// itself is documented thread-safe; every other access to `task`
    /// still only ever happens from this class's own MainActor-isolated
    /// methods.
    nonisolated(unsafe) private var task: URLSessionWebSocketTask?

    init(urlSession: URLSession = URLSession(configuration: .default)) {
        self.urlSession = urlSession
    }

    func connect(apiKey: String, languageHints: [String], targetLanguage: String) {
        let config = SonioxStreamConfig(apiKey: apiKey, languageHints: languageHints, translation: .init(targetLanguage: targetLanguage))
        let task = urlSession.webSocketTask(with: Self.endpoint)
        self.task = task
        Self.openConnectionCount += 1
        Self.lifecycleLogger.log("stream \(self.streamLabel, privacy: .public) connection opened - \(Self.openConnectionCount, privacy: .public) open right now")
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
    /// call, can both reach the same socket) never double-decrements or
    /// double-logs the open count.
    nonisolated func close() {
        guard task != nil else { return }
        task?.cancel(with: .normalClosure, reason: nil)
        task?.cancel()
        task = nil
        Self.openConnectionCount -= 1
        Self.lifecycleLogger.log("stream \(self.streamLabel, privacy: .public) connection closed - \(Self.openConnectionCount, privacy: .public) open right now")
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
