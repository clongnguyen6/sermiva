import Foundation

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

    func connect(config: SonioxStreamConfig) {
        let task = urlSession.webSocketTask(with: Self.endpoint)
        self.task = task
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
    nonisolated func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
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
        onEvent?(.response(response))
    }
}
