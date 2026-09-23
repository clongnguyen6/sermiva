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
/// `SonioxLiveSession` for the real implementation, `SonioxJoinEngine` for
/// where the M-only segment assembly is proven, and `MeTranslationQueue`
/// for the on-device `me -> target` translation queue this protocol also
/// exposes (`makeTranslationRequests`/`reportTranslation...`) - the narrow
/// interface `ConversationView`'s `.translationTask` closure drives, per
/// docs/soniox-routing.md and the outcome's fatalError rules.
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
    /// Closes the socket synchronously, with no finalize/empty-frame
    /// sequence and no wait - appropriate once the server has already
    /// rejected the key (401/402/403): a graceful finalize has nothing
    /// left to accomplish, and the caller (an auth-error exit) needs the
    /// guarantee that no socket survives past this call.
    func endImmediately(completion: @escaping @MainActor () -> Void)

    /// A fresh stream every call (fatalError rule 4) of final `me`-language
    /// segments waiting to be translated on-device, one at a time, in
    /// order. `ConversationView`'s `.translationTask` closure is the only
    /// consumer - `TranslationSession` never appears on this seam.
    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)>
    /// Called the instant the closure actually starts translating `id` -
    /// not when it was merely queued (fatalError rule 7).
    func reportTranslationStarted(id: Int)
    /// Writes the whole translated text once.
    func reportTranslationSuccess(id: Int, target: String)
    /// An error means "no translation" - never retried automatically
    /// (fatalError rule 8).
    func reportTranslationFailure(id: Int)
}

/// Owns the single `one_way(me)` socket from docs/soniox-routing.md, the
/// audio buffering that lets it start streaming cleanly, keepalive during
/// pause, and reconnect (with retry/backoff) on an unexpected drop.
/// Everything this class decides about what an M token *means* is
/// delegated to `SonioxJoinEngine`; on-device `me -> target` translation is
/// queued through `MeTranslationQueue` and reported back into the same
/// engine, so `segments` keeps exactly one writer. The one thing that stays
/// untested is the adapter that turns real WebSocket bytes into
/// `SonioxSocketEvent` - `SonioxStreamSocket` itself - per AGENTS.md.
@MainActor
final class SonioxLiveSession: SonioxLiveSessionProtocol {
    var onSegmentsChanged: (@MainActor ([Segment]) -> Void)?
    var onAuthError: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnected: (@MainActor () -> Void)?

    // `nonisolated(unsafe)`: both are set once, only from `init` (itself
    // `nonisolated`, for the default-parameter-value reason below), and
    // never mutated again - only ever read from this class's own
    // MainActor-isolated methods afterward.
    nonisolated(unsafe) private let makeSocket: @MainActor () -> SonioxSocketConnecting
    nonisolated(unsafe) private let scheduler: DemoScheduler

    private var config: SonioxSessionConfig?
    private var socket: SonioxSocketConnecting?
    private var joinEngine: SonioxJoinEngine?

    /// Persists across "Phiên mới" (this object is reused, only
    /// `joinEngine` is recreated) purely so translation request ids never
    /// repeat - see `enqueueMeTranslation` and `translationRequestSegmentId`
    /// below for why that is what keeps a stale, still-in-flight on-device
    /// translation from a just-ended session from ever landing on a
    /// same-numbered segment in the next one.
    private let translationQueue = MeTranslationQueue()
    private var nextTranslationRequestId = 1
    private var translationRequestSegmentId: [Int: Int] = [:]

    private var configSent = false
    private var bufferedAudio: [Data] = []
    private var bufferedAudioByteCount = 0
    /// 60 s of the converted 16 kHz mono Int16 stream (32,000 bytes/s) -
    /// an exact duration, independent of whatever sample rate the device's
    /// microphone hardware happens to be capturing at (a chunk-count bound
    /// would not have this property: each tap callback's own duration
    /// varies with the hardware rate). See docs/soniox-routing.md's
    /// reconnecting section for what happens to audio beyond this bound,
    /// and what the buffer means across a multi-attempt outage.
    private let bufferedAudioMaxBytes = 60 * 32_000
    /// Set once the current socket has genuinely started streaming (config
    /// sent, first buffered flush done). `false` during the initial
    /// connect and during a reconnect, so `ingestAudio` buffers until the
    /// (possibly brand-new) socket has accepted its config.
    private var hasStartedStreaming = false
    private var isEnding = false
    /// `true` from the moment a drop is first detected until a replacement
    /// socket has reported its config sent. Distinguishes "this is the
    /// first drop, run the abandon/notify dance" from "this is a retry's
    /// own socket failing again, just retry" - see `handleDrop`.
    private var isReconnecting = false
    /// Every socket this session ever opens is stamped with the
    /// generation active when it was created. `handle` discards any event
    /// whose generation does not match the current one. Bumped the moment
    /// a drop is first processed (before anything else runs) - not only
    /// when a replacement socket is actually created - so a stale event
    /// from an already-superseded socket is immediately recognised, rather
    /// than being treated as an independent second drop that would
    /// schedule an overlapping retry timer.
    private var connectionGeneration = 0
    /// Bumped only when a genuinely new session begins (`start`) or the
    /// current one is torn down (`prepareToEnd`) - unlike
    /// `connectionGeneration`, this does NOT change on every reconnect
    /// attempt within one session. `.authRejected` is checked against this
    /// instead of `connectionGeneration`, so it still wins across a
    /// session's own reconnect attempts, but a stale auth event from an
    /// already-ended session can never resurrect it, and can never leak
    /// into a later session that reuses this same object (`start` is
    /// called again for "Phiên mới").
    private var sessionEpoch = 0
    private var reconnectAttempt = 0
    private let reconnectBaseDelay: TimeInterval = 1
    private let reconnectMaxDelay: TimeInterval = 30
    /// Set only while `start(config:completion:)` has not yet settled, so
    /// `handle` can tell an initial connection failure/success apart from
    /// a later reconnect's - the two must not share one completion path.
    /// Per HANDOFF section 6, retry/backoff is a `reconnecting` (mid-
    /// session) behaviour; an initial connect failure is not retried here -
    /// `LiveSessionController` already gives the user their own retry via
    /// tapping Bắt đầu again.
    private var pendingStartCompletion: (@MainActor (Bool) -> Void)?
    private var keepaliveTimer: Timer?

    // `nonisolated` so `LiveSessionController`'s default parameter value
    // (`= SonioxLiveSession()`) can construct one without already running
    // on the main actor - default argument expressions do not inherit the
    // enclosing type's actor isolation.
    nonisolated init(
        makeSocket: @escaping @MainActor () -> SonioxSocketConnecting = { SonioxStreamSocket() },
        scheduler: DemoScheduler = DispatchScheduler()
    ) {
        self.makeSocket = makeSocket
        self.scheduler = scheduler
    }

    /// Guarantees no socket survives this object, even if `end`/
    /// `endImmediately` was never called (e.g. the owning
    /// `LiveSessionController` was simply torn down) or its completion
    /// never got to fire - see `SonioxStreamSocket.close()`'s own
    /// synchronous cancel.
    deinit {
        socket?.close()
    }

    func start(config: SonioxSessionConfig, completion: @escaping @MainActor (Bool) -> Void) {
        self.config = config
        isEnding = false
        isReconnecting = false
        sessionEpoch += 1
        reconnectAttempt = 0
        configSent = false
        bufferedAudio = []
        bufferedAudioByteCount = 0
        hasStartedStreaming = false
        let engine = SonioxJoinEngine(meLanguage: config.meLanguage)
        engine.onMeSegmentFinalized = { [weak self] segmentId, source in
            self?.enqueueMeTranslation(segmentId: segmentId, source: source)
        }
        joinEngine = engine
        // `translationQueue` persists across "Phiên mới" (unlike
        // `joinEngine`, recreated per `start()` above) - wired here (a
        // MainActor-isolated method, unlike `init`, which is deliberately
        // `nonisolated` - see its own doc comment) every session start;
        // harmless to re-wire the same way each time.
        translationQueue.onAbandoned = { [weak self] requestId in
            self?.handleTranslationAbandoned(requestId: requestId)
        }

        var settled = false
        pendingStartCompletion = { [weak self] ok in
            guard !settled else { return }
            settled = true
            self?.pendingStartCompletion = nil
            completion(ok)
        }
        connectFresh()
    }

    func ingestAudio(_ data: Data) {
        guard hasStartedStreaming else {
            // Initial connect, or mid-reconnect: buffer until the current
            // socket has accepted its config.
            guard configSent else {
                appendBufferedAudio(data)
                return
            }
            hasStartedStreaming = true
            socket?.sendAudio(data)
            return
        }
        socket?.sendAudio(data)
    }

    private func appendBufferedAudio(_ data: Data) {
        bufferedAudio.append(data)
        bufferedAudioByteCount += data.count
        while bufferedAudioByteCount > bufferedAudioMaxBytes, !bufferedAudio.isEmpty {
            bufferedAudioByteCount -= bufferedAudio.removeFirst().count
        }
    }

    private func clearBufferedAudio() {
        bufferedAudio = []
        bufferedAudioByteCount = 0
    }

    func beginPauseKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.socket?.sendKeepalive()
            }
        }
    }

    func endPauseKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }

    func end(completion: @escaping @MainActor () -> Void) {
        prepareToEnd()
        socket?.sendFinalize()
        socket?.sendEmptyFrame()
        // The docs' end sequence waits for `finished`, then closes; this
        // app is not the one that gets to hold a metered stream open
        // indefinitely waiting for it, so a short grace window stands in
        // for that wait, and `close()` always runs after it either way.
        scheduler.schedule(after: 1.5) { [weak self] in
            self?.socket?.close()
            completion()
        }
    }

    func endImmediately(completion: @escaping @MainActor () -> Void) {
        prepareToEnd()
        socket?.close()
        completion()
    }

    private func prepareToEnd() {
        isEnding = true
        isReconnecting = false
        reconnectAttempt = 0
        connectionGeneration += 1
        sessionEpoch += 1
        pendingStartCompletion = nil
        endPauseKeepalive()
        // Ending is the "obvious choice" for what a reconnect's buffered
        // audio means once the outage it was captured for is simply not
        // going to be sent anywhere: it stops meaning anything the moment
        // this session is over. Observably redundant with `start`'s own
        // reset in the one reachable "reused for Phien moi" scenario
        // (kept as regression coverage below) - this one exists so the
        // session's own state is honest and consistent with itself
        // immediately after `end`/`endImmediately`, not only once
        // something later happens to call `start` again.
        clearBufferedAudio()
        // Abandons any still-queued or in-flight on-device translation -
        // NOT the underlying stream itself (see `MeTranslationQueue.abandonAll`):
        // `.translationTask`'s closure and its stream live for the whole
        // conversation, across "Phiên mới", so they must keep working for
        // the next session.
        translationQueue.abandonAll()
        // Same reasoning for the M-direct (non-`me`) in-progress translations
        // a reconnect already abandons explicitly (docs/soniox-routing.md),
        // so the internal state stays honest rather than silently depending
        // on the server's own `<fin>` arriving before `close()` fires -
        // `end`/`endImmediately` must not be the one path left where a
        // still-pending one quietly goes stale instead.
        joinEngine?.abandonMDirectTranslationsInProgress()
        if let engine = joinEngine {
            onSegmentsChanged?(engine.segments)
        }
    }

    private func handle(_ event: SonioxSocketEvent, generation: Int, epoch: Int) {
        // Auth wins across a session's own reconnect attempts - deliberately
        // NOT behind the generation guard below, which exists to filter
        // stale reconnect-attempt noise, not a terminal "the key is
        // rejected" signal that matters regardless of which attempt
        // reported it. It IS gated on the session epoch, though: once this
        // session has ended (or `start` began a brand-new one reusing this
        // same object, for "Phiên mới"), a straggler auth event from the
        // old session must not resurrect it or leak into the new one.
        if case .authRejected = event {
            guard epoch == sessionEpoch else { return }
            onAuthError?()
            return
        }
        guard generation == connectionGeneration else { return }
        switch event {
        case .authRejected:
            break // handled above, unreachable here
        case .configSent:
            configSent = true
            flushBufferedAudioIfReady()
            reconnectAttempt = 0
            if let completion = pendingStartCompletion {
                pendingStartCompletion = nil
                completion(true)
            } else if isReconnecting {
                isReconnecting = false
                onReconnected?()
            }
        case .response(let response):
            guard let engine = joinEngine else { return }
            engine.applyStreamM(response.tokens)
            onSegmentsChanged?(engine.segments)
        case .closed:
            guard !isEnding else { return }
            if let completion = pendingStartCompletion {
                pendingStartCompletion = nil
                completion(false)
                return
            }
            // Move this socket out of "current" immediately - a second
            // close event from the SAME socket must be recognised as
            // stale by the guard above, not treated as an independent
            // second drop.
            connectionGeneration += 1
            handleDrop()
        }
    }

    private func flushBufferedAudioIfReady() {
        guard configSent, !bufferedAudio.isEmpty else { return }
        for chunk in bufferedAudio {
            socket?.sendAudio(chunk)
        }
        clearBufferedAudio()
    }

    /// The first drop runs the abandon/notify dance once; if the
    /// replacement socket itself then fails before ever finishing that
    /// dance, this just retries - `isReconnecting` already being `true` is
    /// what tells the two cases apart. Captured audio is NOT cleared here:
    /// it keeps accumulating (bounded by `bufferedAudioMaxBytes`) across
    /// every attempt of one continuous outage, and is only ever cleared by
    /// a successful flush (`flushBufferedAudioIfReady`) or by ending the
    /// session - a failed attempt must not throw away what the mic
    /// captured while the app was still trying.
    private func handleDrop() {
        if !isReconnecting {
            isReconnecting = true
            reconnectAttempt = 0
            joinEngine?.closeOpenSegmentForReconnect()
            joinEngine?.abandonMDirectTranslationsInProgress()
            joinEngine?.handleStreamMReconnected()
            if let engine = joinEngine {
                onSegmentsChanged?(engine.segments)
            }
            onDisconnected?()
        }

        socket?.close()
        socket = nil
        configSent = false
        hasStartedStreaming = false

        scheduleReconnectAttempt()
    }

    /// HANDOFF section 6: "retry backoff". Doubles from `reconnectBaseDelay`
    /// up to `reconnectMaxDelay`, resetting to zero the moment the socket
    /// fully connects again (`handle`'s `.configSent` branch). Checks
    /// `isReconnecting`/`isEnding` again when it actually fires, since a
    /// lot can happen during the wait: the session could have ended, or an
    /// auth error could have already won.
    private func scheduleReconnectAttempt() {
        let delay = min(reconnectMaxDelay, reconnectBaseDelay * pow(2, Double(reconnectAttempt)))
        reconnectAttempt += 1
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.isReconnecting, !self.isEnding else { return }
            self.connectFresh()
        }
    }

    /// Opens a brand-new socket against the current `config` and wires it
    /// back into `handle`, stamped with a freshly-incremented generation so
    /// any lingering event from a superseded socket is discarded rather
    /// than mistaken for this socket's own status. Used both for the
    /// initial connect and for every reconnect/retry attempt.
    private func connectFresh() {
        guard let config else { return }
        connectionGeneration += 1
        let generation = connectionGeneration
        let epoch = sessionEpoch

        var hints = [config.meLanguage, config.targetLanguage]
        if let guestHint = config.guestHint { hints.append(guestHint) }

        let newSocket = makeSocket()
        socket = newSocket

        newSocket.onEvent = { [weak self] event in self?.handle(event, generation: generation, epoch: epoch) }

        newSocket.connect(apiKey: config.apiKey, languageHints: hints, targetLanguage: config.meLanguage)
    }

    // MARK: - On-device me -> target translation

    private func enqueueMeTranslation(segmentId: Int, source: String) {
        let requestId = nextTranslationRequestId
        nextTranslationRequestId += 1
        translationRequestSegmentId[requestId] = segmentId
        translationQueue.enqueue(id: requestId, source: source)
    }

    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)> {
        translationQueue.makeRequests()
    }

    func reportTranslationStarted(id: Int) {
        guard let segmentId = translationRequestSegmentId[id] else { return }
        joinEngine?.applyTranslationStarted(segmentId: segmentId)
        if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
    }

    func reportTranslationSuccess(id: Int, target: String) {
        guard let segmentId = translationRequestSegmentId.removeValue(forKey: id) else { return }
        translationQueue.finished(id: id)
        joinEngine?.applyTranslationSuccess(segmentId: segmentId, target: target)
        if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
    }

    func reportTranslationFailure(id: Int) {
        guard let segmentId = translationRequestSegmentId.removeValue(forKey: id) else { return }
        translationQueue.finished(id: id)
        joinEngine?.applyTranslationFailure(segmentId: segmentId)
        if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
    }

    private func handleTranslationAbandoned(requestId: Int) {
        guard let segmentId = translationRequestSegmentId.removeValue(forKey: requestId) else { return }
        joinEngine?.applyTranslationFailure(segmentId: segmentId)
        if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
    }
}
