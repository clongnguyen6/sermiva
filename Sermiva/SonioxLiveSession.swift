import Foundation

struct SonioxSessionConfig {
    let apiKey: String
    let meLanguage: String
    let targetLanguage: String
    let guestHint: String?
}

/// What `LiveSessionController` drives - real network and audio-buffering
/// behind a small, fake-able surface, so the controller's state-machine
/// wiring is testable without ever opening a socket. See
/// `SonioxLiveSession` for the real implementation and
/// `SonioxJoinEngine`/`SonioxJoinEngineTests` for where the actual join
/// logic is proven.
@MainActor
protocol SonioxLiveSessionProtocol: AnyObject {
    var onSegmentsChanged: (@MainActor ([Segment]) -> Void)? { get set }
    var onAuthError: (@MainActor () -> Void)? { get set }
    var onDisconnected: (@MainActor () -> Void)? { get set }
    var onReconnected: (@MainActor () -> Void)? { get set }

    func start(config: SonioxSessionConfig, completion: @escaping @MainActor (Bool) -> Void)
    func ingestAudio(_ data: Data)
    func beginPauseKeepalive()
    func endPauseKeepalive()
    func end(completion: @escaping @MainActor () -> Void)
}

/// Owns the two `one_way` sockets from docs/soniox-routing.md, the audio
/// buffering that gives both streams the same origin, keepalive during
/// pause, and reconnect on an unexpected drop. Everything it decides about
/// what a token *means* is delegated to `SonioxJoinEngine`; this class only
/// moves bytes and lifecycle events. Not covered by
/// `SermivaTests` - see `SonioxStreamSocket`'s header for why.
@MainActor
final class SonioxLiveSession: SonioxLiveSessionProtocol {
    var onSegmentsChanged: (@MainActor ([Segment]) -> Void)?
    var onAuthError: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnected: (@MainActor () -> Void)?

    private var config: SonioxSessionConfig?
    private var streamM: SonioxStreamSocket?
    private var streamT: SonioxStreamSocket?
    private var joinEngine: SonioxJoinEngine?

    private var mConfigSent = false
    private var tConfigSent = false
    private var bufferedAudio: [Data] = []
    /// Set once the current pair of sockets has genuinely started
    /// streaming (both configs sent, first buffered flush done). `false`
    /// during the initial connect and during a reconnect, so `ingestAudio`
    /// buffers until the (possibly brand-new) pair shares one
    /// byte-identical origin again - see the reconnecting section of
    /// docs/soniox-routing.md.
    private var hasStartedStreaming = false
    private var isEnding = false
    /// `true` from the moment either socket drops until the new pair has
    /// both reported their config sent. Guards against a second `.closed`
    /// (the other socket dropping too, or a stale event from a socket this
    /// class itself just closed) re-triggering a second reconnect cycle.
    private var isReconnecting = false
    /// Set only while `start(config:completion:)` has not yet settled, so
    /// `handle` can tell an initial connection failure/success apart from
    /// a later reconnect's - the two must not share one completion path.
    private var pendingStartCompletion: (@MainActor (Bool) -> Void)?
    private var keepaliveTimer: Timer?

    // `nonisolated` so `LiveSessionController`'s default parameter value
    // (`= SonioxLiveSession()`) can construct one without already running
    // on the main actor - default argument expressions do not inherit the
    // enclosing type's actor isolation.
    nonisolated init() {}

    func start(config: SonioxSessionConfig, completion: @escaping @MainActor (Bool) -> Void) {
        self.config = config
        isEnding = false
        isReconnecting = false
        mConfigSent = false
        tConfigSent = false
        bufferedAudio = []
        hasStartedStreaming = false
        joinEngine = SonioxJoinEngine(meLanguage: config.meLanguage)

        var settled = false
        pendingStartCompletion = { [weak self] ok in
            guard !settled else { return }
            settled = true
            self?.pendingStartCompletion = nil
            completion(ok)
        }
        connectBothFresh()
    }

    func ingestAudio(_ data: Data) {
        guard hasStartedStreaming else {
            // Initial connect, or mid-reconnect: buffer until the current
            // pair of sockets both share one byte-identical origin, per
            // docs/soniox-routing.md's audio-origin rule.
            guard mConfigSent, tConfigSent else {
                bufferedAudio.append(data)
                return
            }
            hasStartedStreaming = true
            streamM?.sendAudio(data)
            streamT?.sendAudio(data)
            return
        }
        streamM?.sendAudio(data)
        streamT?.sendAudio(data)
    }

    func beginPauseKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.streamM?.sendKeepalive()
                self?.streamT?.sendKeepalive()
            }
        }
    }

    func endPauseKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }

    func end(completion: @escaping @MainActor () -> Void) {
        isEnding = true
        isReconnecting = false
        pendingStartCompletion = nil
        endPauseKeepalive()
        streamM?.sendFinalize()
        streamT?.sendFinalize()
        streamM?.sendEmptyFrame()
        streamT?.sendEmptyFrame()
        // The docs' end sequence waits for `finished` on both, then closes;
        // this app is not the one that gets to hold a metered stream open
        // indefinitely waiting for it, so a short grace window stands in
        // for that wait, and `close()` always runs after it either way.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.streamM?.close()
            self?.streamT?.close()
            completion()
        }
    }

    private func handle(_ event: SonioxStreamSocket.Event, isStreamM: Bool) {
        switch event {
        case .configSent:
            if isStreamM { mConfigSent = true } else { tConfigSent = true }
            flushBufferedAudioIfReady()
            guard mConfigSent, tConfigSent else { return }
            if let completion = pendingStartCompletion {
                pendingStartCompletion = nil
                completion(true)
            } else if isReconnecting {
                isReconnecting = false
                onReconnected?()
            }
        case .response(let response):
            // 401/402/403 are the docs' auth-class errors; 400 is not, and
            // must not be treated as one.
            if let code = response.errorCode, (401...403).contains(code) {
                onAuthError?()
                return
            }
            guard let engine = joinEngine else { return }
            let tokens = (response.tokens ?? []).map { $0.appToken }
            if isStreamM {
                engine.applyStreamM(tokens)
            } else {
                engine.applyStreamT(tokens, finalAudioProcMs: response.finalAudioProcMs ?? 0)
            }
            onSegmentsChanged?(engine.segments)
        case .closed:
            guard !isEnding else { return }
            if let completion = pendingStartCompletion {
                pendingStartCompletion = nil
                completion(false)
                return
            }
            beginDualReconnect()
        }
    }

    private func flushBufferedAudioIfReady() {
        guard mConfigSent, tConfigSent, !bufferedAudio.isEmpty else { return }
        for chunk in bufferedAudio {
            streamM?.sendAudio(chunk)
            streamT?.sendAudio(chunk)
        }
        bufferedAudio.removeAll()
    }

    /// A drop on either socket reconnects BOTH together, so they share one
    /// fresh audio origin again from byte zero - a one-sided reconnect can
    /// never restore a shared origin between two independently-reset
    /// clocks (see docs/soniox-routing.md's reconnecting section for why
    /// that was the previous, now-replaced, approach). Every join still in
    /// flight against the old origin is abandoned immediately - not left
    /// to time out - and M's speaker-letter map is always cleared here,
    /// since M always gets a brand-new diarization connection too: a
    /// post-reconnect speaker must never be displayed with a letter
    /// already shown pre-reconnect unless the data actually says so, and
    /// it never can here, since the app has no way to know a post-drop "1"
    /// is the same person as any pre-drop speaker.
    private func beginDualReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true

        joinEngine?.abandonAllPendingJoins()
        joinEngine?.handleStreamMReconnected()
        if let engine = joinEngine {
            onSegmentsChanged?(engine.segments)
        }
        onDisconnected?()

        streamM?.close()
        streamT?.close()
        streamM = nil
        streamT = nil
        mConfigSent = false
        tConfigSent = false
        hasStartedStreaming = false
        bufferedAudio = []

        connectBothFresh()
    }

    /// Opens a brand-new pair of sockets against the current `config` and
    /// wires both back into `handle`. Used both for the initial connect and
    /// for a reconnect - in both cases the two sockets must come up as one
    /// pair sharing a fresh origin, never independently.
    private func connectBothFresh() {
        guard let config else { return }
        var hints = [config.meLanguage, config.targetLanguage]
        if let guestHint = config.guestHint { hints.append(guestHint) }

        let m = SonioxStreamSocket()
        let t = SonioxStreamSocket()
        streamM = m
        streamT = t

        m.onEvent = { [weak self] event in self?.handle(event, isStreamM: true) }
        t.onEvent = { [weak self] event in self?.handle(event, isStreamM: false) }

        m.connect(config: SonioxStreamConfig(apiKey: config.apiKey, languageHints: hints, translation: .init(targetLanguage: config.meLanguage)))
        t.connect(config: SonioxStreamConfig(apiKey: config.apiKey, languageHints: hints, translation: .init(targetLanguage: config.targetLanguage)))
    }
}
