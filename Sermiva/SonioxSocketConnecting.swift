import Foundation

/// One app-owned response from a Soniox stream - already mapped from the
/// wire format by `SonioxStreamSocket` (the adapter), so `SonioxLiveSession`
/// and everything tested against this seam never sees `SonioxStreamResponse`
/// or `SonioxTokenWire`.
struct SonioxSocketResponse {
    let tokens: [SonioxToken]
    let finalAudioProcMs: Int
}

/// The lifecycle events `SonioxLiveSession`'s reconnect/retry policy reacts
/// to - independent of Soniox's wire format. `SonioxStreamSocket` (the
/// real adapter, untested per AGENTS.md) is the only thing that ever
/// decides `.response` vs `.authRejected`, by inspecting a real decoded
/// response's error code, and the only thing that ever constructs a
/// `SonioxSocketResponse` from wire data; everything downstream of this
/// seam is pure app-level state, exercised in `SonioxLiveSessionTests`
/// through a fake conforming to `SonioxSocketConnecting` below - never
/// through `SonioxStreamSocket`, and never with any Soniox JSON.
enum SonioxSocketEvent {
    case configSent
    case authRejected
    case response(SonioxSocketResponse)
    case closed(Error?)
}

/// What `SonioxLiveSession` actually depends on for one socket - commands
/// it can issue, in app-level terms (a key and languages, not a wire
/// config struct), and the lifecycle events it reacts to.
/// `SonioxStreamSocket` is the real, production conformance and is the
/// only place that ever builds the wire-format config or decodes wire
/// responses; tests inject a fake.
@MainActor
protocol SonioxSocketConnecting: AnyObject {
    var onEvent: ((SonioxSocketEvent) -> Void)? { get set }
    func connect(apiKey: String, languageHints: [String], targetLanguage: String)
    func sendAudio(_ data: Data)
    func sendKeepalive()
    func sendFinalize()
    func sendEmptyFrame()
    /// `nonisolated` so `SonioxLiveSession.deinit` (necessarily nonisolated
    /// for a `@MainActor` class) can guarantee every socket it ever opened
    /// is closed, even if nothing else ever calls this.
    nonisolated func close()
}
