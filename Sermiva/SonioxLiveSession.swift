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
    /// Set once the very first (both-sockets-ready) flush has happened.
    /// Before that, `ingestAudio` buffers until both sockets are ready, so
    /// they share one byte-identical origin (docs/soniox-routing.md's
    /// audio-origin rule). After that, a later reconnect of one socket must
    /// never again pause the *surviving* socket's own live audio feed while
    /// waiting - only the reconnecting socket goes quiet for its own gap.
    private var hasStartedStreaming = false
    private var isEnding = false
    private var keepaliveTimer: Timer?

    // `nonisolated` so `LiveSessionController`'s default parameter value
    // (`= SonioxLiveSession()`) can construct one without already running
    // on the main actor - default argument expressions do not inherit the
    // enclosing type's actor isolation.
    nonisolated init() {}

    func start(config: SonioxSessionConfig, completion: @escaping @MainActor (Bool) -> Void) {
        self.config = config
        isEnding = false
        mConfigSent = false
        tConfigSent = false
        bufferedAudio = []
        hasStartedStreaming = false
        joinEngine = SonioxJoinEngine(meLanguage: config.meLanguage)

        var hints = [config.meLanguage, config.targetLanguage]
        if let guestHint = config.guestHint { hints.append(guestHint) }

        let m = SonioxStreamSocket()
        let t = SonioxStreamSocket()
        streamM = m
        streamT = t

        var mReady = false
        var tReady = false
        var settled = false
        let settle: (Bool) -> Void = { ok in
            guard !settled else { return }
            settled = true
            completion(ok)
        }

        m.onEvent = { [weak self] event in
            self?.handle(event, isStreamM: true)
            if case .configSent = event { mReady = true; if mReady && tReady { settle(true) } }
            if case .closed = event, !settled { settle(false) }
        }
        t.onEvent = { [weak self] event in
            self?.handle(event, isStreamM: false)
            if case .configSent = event { tReady = true; if mReady && tReady { settle(true) } }
            if case .closed = event, !settled { settle(false) }
        }

        m.connect(config: SonioxStreamConfig(apiKey: config.apiKey, languageHints: hints, translation: .init(targetLanguage: config.meLanguage)))
        t.connect(config: SonioxStreamConfig(apiKey: config.apiKey, languageHints: hints, translation: .init(targetLanguage: config.targetLanguage)))
    }

    func ingestAudio(_ data: Data) {
        guard hasStartedStreaming else {
            // Initial startup only: buffer until both sockets share one
            // byte-identical origin, per docs/soniox-routing.md.
            guard mConfigSent, tConfigSent else {
                bufferedAudio.append(data)
                return
            }
            hasStartedStreaming = true
            streamM?.sendAudio(data)
            streamT?.sendAudio(data)
            return
        }
        // Once streaming has genuinely started, a later reconnect of one
        // socket must not corrupt the surviving socket's own timeline by
        // withholding its live audio while the other one is down - each
        // ready socket gets audio independently; a reconnecting socket
        // simply misses audio during its own gap (its timeline restarts
        // regardless, per the reconnecting section of the routing doc).
        if mConfigSent { streamM?.sendAudio(data) }
        if tConfigSent { streamT?.sendAudio(data) }
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
            // The dropped socket's replacement gets a fresh, zero-based
            // timeline (docs/soniox-routing.md), so every join still in
            // flight against the old shared origin must be abandoned now -
            // not left to time out on its own, and not compared against
            // timestamps that no longer share an origin with it.
            joinEngine?.abandonAllPendingJoins()
            if isStreamM {
                joinEngine?.handleStreamMReconnected()
            }
            if let engine = joinEngine {
                onSegmentsChanged?(engine.segments)
            }
            onDisconnected?()
            reconnect(isStreamM: isStreamM)
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

    /// Reopens the dropped socket only - `handle`'s `.closed` branch has
    /// already abandoned every in-flight join and, for an M drop, cleared
    /// the speaker-letter map before this runs. What this does NOT do:
    /// realign the reconnected socket's new zero-based timeline with the
    /// surviving socket's old one. If only one side reconnects, its future
    /// windows are computed on a fresh clock while the other stream is
    /// still on the original one, so new joins on the reconnected side
    /// will simply fail to find a match (safe - never a wrong translation,
    /// per the no-guess rule - but no `me`-language segment gets a
    /// translation either, for the rest of the session, until the other
    /// side also reconnects and both share a fresh origin again). This is
    /// a deliberate simplification, not a general fix - see
    /// docs/soniox-routing.md's reconnecting section and the hand-off
    /// report's owner questions.
    private func reconnect(isStreamM: Bool) {
        guard let config else { return }
        let hints: [String] = {
            var h = [config.meLanguage, config.targetLanguage]
            if let guestHint = config.guestHint { h.append(guestHint) }
            return h
        }()
        let target = isStreamM ? config.meLanguage : config.targetLanguage
        let socket = SonioxStreamSocket()
        socket.onEvent = { [weak self] event in
            self?.handle(event, isStreamM: isStreamM)
            if case .configSent = event {
                Task { @MainActor in self?.onReconnected?() }
            }
        }
        if isStreamM {
            streamM = socket
            mConfigSent = false
        } else {
            streamT = socket
            tConfigSent = false
        }
        socket.connect(config: SonioxStreamConfig(apiKey: config.apiKey, languageHints: hints, translation: .init(targetLanguage: target)))
    }
}
