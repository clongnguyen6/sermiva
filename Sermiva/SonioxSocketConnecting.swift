import Foundation

/// The lifecycle events `SonioxLiveSession`'s reconnect/retry policy reacts
/// to - independent of Soniox's wire format. `SonioxStreamSocket` (the
/// real adapter, untested per AGENTS.md) is the only thing that ever
/// decides `.response` vs `.authRejected`, by inspecting a real decoded
/// response's error code; everything downstream of this seam is pure
/// app-level state, exercised in `SonioxLiveSessionTests` through a fake
/// conforming to `SonioxSocketConnecting` below - never through
/// `SonioxStreamSocket`, and never with any Soniox JSON.
enum SonioxSocketEvent {
    case configSent
    case authRejected
    case response(SonioxStreamResponse)
    case closed(Error?)
}

/// What `SonioxLiveSession` actually depends on for one socket - commands
/// it can issue, and the lifecycle events it reacts to. `SonioxStreamSocket`
/// is the real, production conformance; tests inject a fake.
@MainActor
protocol SonioxSocketConnecting: AnyObject {
    var onEvent: ((SonioxSocketEvent) -> Void)? { get set }
    func connect(config: SonioxStreamConfig)
    func sendAudio(_ data: Data)
    func sendKeepalive()
    func sendFinalize()
    func sendEmptyFrame()
    /// `nonisolated` so `SonioxLiveSession.deinit` (necessarily nonisolated
    /// for a `@MainActor` class) can guarantee every socket it ever opened
    /// is closed, even if nothing else ever calls this.
    nonisolated func close()
}
