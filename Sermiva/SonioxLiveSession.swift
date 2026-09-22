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
        guard mConfigSent, tConfigSent else {
            bufferedAudio.append(data)
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
            if let code = response.errorCode, (400...403).contains(code) {
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

    /// Reopening a dropped socket restarts that stream's own timeline (see
    /// docs/soniox-routing.md's reconnecting bullet); any join windows
    /// already pending on the dropped stream stay abandoned rather than
    /// waiting on tokens that will never arrive with the old numbering.
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
