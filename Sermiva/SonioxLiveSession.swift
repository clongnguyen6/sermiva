import Foundation
import os

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

    /// Set by `LiveSessionController` once its own per-session availability
    /// check resolves - `true` only for `.installed`. `false` by default and
    /// reset to `false` at every `start()`, so a `me` segment finalizing
    /// before that check has even completed fails closed (never enqueued)
    /// rather than racing it. See docs/soniox-routing.md.
    func setTranslationAvailable(_ available: Bool)
    /// A fresh stream every call (fatalError rule 4) of final `me`-language
    /// segments waiting to be translated on-device, one at a time, in
    /// order. `ConversationView`'s `.translationTask` closure is the only
    /// consumer - `TranslationSession` never appears on this seam.
    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)>
    /// Called the instant the closure is about to translate `id` - not when
    /// it was merely queued (fatalError rule 7). Returns `false` when `id`
    /// is no longer recognised (already abandoned - by a session end, an
    /// availability drop, or stream termination) or translation is
    /// currently unavailable: the closure must skip the actual `translate`
    /// call entirely in that case, never call it just to discard the
    /// result. Returns `true` only when the closure should actually call
    /// `translate` and show "Đang dịch…" for `id`.
    func reportTranslationStarted(id: Int) -> Bool
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
    nonisolated(unsafe) private let makePathMonitor: @MainActor () -> NetworkPathMonitoring

    /// Review round 5, finding A: a unique id for this OBJECT (not this
    /// session attempt - it persists across "Phiên mới", like the object
    /// itself), logged alongside every connection-lifecycle line so the
    /// owner's next live session can tell directly from the Console whether
    /// more than one `SonioxLiveSession` was ever alive at once - one of
    /// the hypotheses still open in the still-unexplained two-socket
    /// evidence.
    let sessionId = LifecycleIds.session.next()

    private var config: SonioxSessionConfig?
    private var socket: SonioxSocketConnecting?
    private var joinEngine: SonioxJoinEngine?
    /// Review round 4, finding 4a (owner decision): reconnect the instant
    /// iOS reports the network path is available again, instead of waiting
    /// out backoff. Created in `start(config:)`, cancelled in
    /// `prepareToEnd` - a session-lifetime resource, like `keepaliveTimer`.
    private var pathMonitor: NetworkPathMonitoring?

    /// Persists across "Phiên mới" (this object is reused, only
    /// `joinEngine` is recreated) purely so translation request ids never
    /// repeat - see `enqueueMeTranslation` and `translationRequestSegmentId`
    /// below for why that is what keeps a stale, still-in-flight on-device
    /// translation from a just-ended session from ever landing on a
    /// same-numbered segment in the next one.
    private let translationQueue = MeTranslationQueue()
    private var nextTranslationRequestId = 1
    private var translationRequestSegmentId: [Int: Int] = [:]
    /// Set by `LiveSessionController` via `setTranslationAvailable` once its
    /// own per-session availability check resolves. `false` by default and
    /// reset at every `start()` - fail closed until explicitly confirmed, so
    /// nothing is ever enqueued/translated on a guess while that check is
    /// still in flight. See docs/soniox-routing.md.
    private var isTranslationAvailable = false

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
    /// Review round 4, finding 3 (owner decision): audio already sent to
    /// the CURRENT socket but not yet confirmed finalized by it (per
    /// `final_audio_proc_ms`) - resent to a NEW socket FIRST on reconnect,
    /// before the outage buffer (`bufferedAudio` above). In the first mock
    /// session, speech Soniox had not yet finalized when the network
    /// dropped was lost for good: the open segment kept only final text
    /// (`SonioxJoinEngine.closeOpenSegmentForReconnect`), and that audio had
    /// already been sent to the now-dead socket, never to be finalized.
    /// Bounded independently of the outage buffer - 15 s of the converted
    /// stream (480,000 bytes) - since normal finalization latency is far
    /// shorter than that; the pathological case (Soniox never finalizing)
    /// drops the oldest audio rather than grow unbounded, same reasoning as
    /// `bufferedAudioMaxBytes`.
    private var unfinalizedSentAudio: [Data] = []
    private var unfinalizedSentAudioByteCount = 0
    private let unfinalizedSentAudioMaxBytes = 15 * 32_000
    /// Review round 5, finding B2 (blocking): `final_audio_proc_ms` is
    /// CUMULATIVE for the current socket's whole connection, not a delta
    /// since the last response - this is how many of those cumulative bytes
    /// have already been trimmed from `unfinalizedSentAudio`, so
    /// `trimFinalizedAudio` can compute the genuinely NEW amount to trim on
    /// each response instead of re-applying the full cumulative figure to
    /// whatever the buffer happens to hold at that moment (which over-trims
    /// more and more with every response, eventually trimming audio that
    /// was never actually finalized). Reset to 0 in `connectFresh`, since a
    /// brand-new socket's own `final_audio_proc_ms` starts back at 0 too.
    private var finalizedByteWatermark = 0
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
    /// Review round 4, finding 1: how many connection attempts THIS session
    /// (since the last `start()`) has made - the initial connect counts as
    /// #1, every reconnect/retry increments it further. Reset in `start()`,
    /// unlike `connectionGeneration` (which never resets, even across
    /// "Phiên mới"). Purely a logging aid alongside
    /// `SonioxStreamSocket`'s own open/close count - together they let a
    /// live session's Console log show both "how many attempts this
    /// session has made" and "how many are open right now".
    private var sessionConnectionAttempt = 0
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
    /// Bumped every time `scheduleReconnectAttempt` schedules a backoff
    /// timer, and again the instant `handlePathAvailable` preempts one -
    /// the scheduled closure checks this against the value it captured, so
    /// an old backoff timer that fires anyway after being preempted is
    /// recognised as stale and does nothing, rather than opening a SECOND
    /// connection alongside the one `handlePathAvailable` already opened.
    private var reconnectScheduleToken = 0

    // `nonisolated` so `LiveSessionController`'s default parameter value
    // (`= SonioxLiveSession()`) can construct one without already running
    // on the main actor - default argument expressions do not inherit the
    // enclosing type's actor isolation.
    nonisolated init(
        makeSocket: @escaping @MainActor () -> SonioxSocketConnecting = { SonioxStreamSocket() },
        scheduler: DemoScheduler = DispatchScheduler(),
        makePathMonitor: @escaping @MainActor () -> NetworkPathMonitoring = { RealNetworkPathMonitor() }
    ) {
        self.makeSocket = makeSocket
        self.scheduler = scheduler
        self.makePathMonitor = makePathMonitor
        lifecycleLogger.log("session #\(self.sessionId, privacy: .public) created")
    }

    /// Guarantees no socket survives this object, even if `end`/
    /// `endImmediately` was never called (e.g. the owning
    /// `LiveSessionController` was simply torn down) or its completion
    /// never got to fire - see `SonioxStreamSocket.close()`'s own
    /// synchronous cancel.
    deinit {
        socket?.close()
        pathMonitor?.cancel()
        lifecycleLogger.log("session #\(self.sessionId, privacy: .public) deinit")
    }

    func start(config: SonioxSessionConfig, completion: @escaping @MainActor (Bool) -> Void) {
        lifecycleLogger.log("session #\(self.sessionId, privacy: .public) start() called")
        self.config = config
        isEnding = false
        isReconnecting = false
        sessionEpoch += 1
        reconnectAttempt = 0
        configSent = false
        bufferedAudio = []
        bufferedAudioByteCount = 0
        clearUnfinalizedSentAudio()
        hasStartedStreaming = false
        isTranslationAvailable = false
        sessionConnectionAttempt = 0
        pathMonitor?.cancel()
        let monitor = makePathMonitor()
        monitor.onPathAvailable = { [weak self] in self?.handlePathAvailable() }
        monitor.start()
        pathMonitor = monitor
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
            sendAndTrackAudio(data)
            return
        }
        sendAndTrackAudio(data)
    }

    /// Review round 4, finding 3: every chunk actually sent to the current
    /// socket is also kept in `unfinalizedSentAudio` until Soniox's own
    /// `final_audio_proc_ms` (see `trimFinalizedAudio`) confirms it has been
    /// finalized - this is what a reconnect resends first, per the owner's
    /// decision, before the outage buffer.
    private func sendAndTrackAudio(_ data: Data) {
        socket?.sendAudio(data)
        unfinalizedSentAudio.append(data)
        unfinalizedSentAudioByteCount += data.count
        while unfinalizedSentAudioByteCount > unfinalizedSentAudioMaxBytes, !unfinalizedSentAudio.isEmpty {
            unfinalizedSentAudioByteCount -= unfinalizedSentAudio.removeFirst().count
        }
    }

    /// Called from `.response` with Soniox's own `final_audio_proc_ms` - a
    /// CUMULATIVE figure for the current socket's whole connection, per the
    /// docs, converted to bytes at the fixed 32,000 bytes/s rate this app
    /// always converts the mic stream to. Review round 5, finding B2
    /// (blocking): computes only the NEWLY-finalized amount since
    /// `finalizedByteWatermark`'s last value, and trims exactly that much
    /// from the front of `unfinalizedSentAudio` - re-applying the raw
    /// cumulative figure directly against whatever the buffer holds AT THAT
    /// MOMENT (the previous version) over-trims on every response after the
    /// first, since bytes already trimmed by an earlier response are no
    /// longer there to (harmlessly) re-consume - it instead eats into audio
    /// that was never actually finalized. Splits the one chunk that
    /// straddles the boundary so nothing already-finalized is ever resent
    /// (which would duplicate a segment) and nothing still-open is ever
    /// dropped.
    private func trimFinalizedAudio(finalAudioProcMs: Int) {
        let cumulativeFinalizedBytes = (finalAudioProcMs * 32_000) / 1000
        var newlyFinalizedBytes = cumulativeFinalizedBytes - finalizedByteWatermark
        guard newlyFinalizedBytes > 0 else { return }
        while newlyFinalizedBytes > 0, let first = unfinalizedSentAudio.first {
            if first.count <= newlyFinalizedBytes {
                newlyFinalizedBytes -= first.count
                unfinalizedSentAudioByteCount -= first.count
                unfinalizedSentAudio.removeFirst()
            } else {
                let remainder = first.dropFirst(newlyFinalizedBytes)
                unfinalizedSentAudioByteCount -= newlyFinalizedBytes
                unfinalizedSentAudio[0] = Data(remainder)
                newlyFinalizedBytes = 0
            }
        }
        // Tracks the server's reported position regardless of whether the
        // buffer actually held enough bytes to consume (it may not, if the
        // 15 s bound above already evicted some) - future calls must keep
        // computing the delta against the true cumulative figure, not
        // against how much this call happened to find.
        finalizedByteWatermark = cumulativeFinalizedBytes
    }

    private func clearUnfinalizedSentAudio() {
        unfinalizedSentAudio = []
        unfinalizedSentAudioByteCount = 0
    }

    /// Replays whatever `unfinalizedSentAudio` currently holds to the just-
    /// (re)connected socket. The bytes are already present in that buffer -
    /// this reconnect's whole point is that Soniox never confirmed them
    /// finalized - so this only resends; it must not append them again, or
    /// the buffer would grow every reconnect.
    private func resendUnfinalizedAudioIfAny() {
        guard !unfinalizedSentAudio.isEmpty else { return }
        for chunk in unfinalizedSentAudio {
            socket?.sendAudio(chunk)
        }
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
        // Review round 5, finding B1 (blocking): captured HERE, once, not
        // re-read as `self?.socket` when the scheduled closure below
        // actually fires. If "Phiên mới" starts a brand-new session within
        // the 1.5 s wait, `self.socket` will already point at the NEW
        // session's socket by then - reading it fresh at fire time closed
        // that new socket instead, per the reviewer's own reproduction. This
        // closure now always closes the exact socket THIS `end()` call was
        // for, and only clears `self.socket` if nothing newer has replaced
        // it since (the `self.socket === socketToClose` check).
        let socketToClose = socket
        socketToClose?.sendFinalize()
        socketToClose?.sendEmptyFrame()
        // The docs' end sequence waits for `finished`, then closes; this
        // app is not the one that gets to hold a metered stream open
        // indefinitely waiting for it, so a short grace window stands in
        // for that wait, and `close()` always runs after it either way.
        scheduler.schedule(after: 1.5) { [weak self] in
            socketToClose?.close()
            if let self, self.socket === socketToClose {
                self.socket = nil
            }
            completion()
        }
    }

    func endImmediately(completion: @escaping @MainActor () -> Void) {
        prepareToEnd()
        socket?.close()
        socket = nil
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
        pathMonitor?.cancel()
        pathMonitor = nil
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
        clearUnfinalizedSentAudio()
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
            // Review round 4, finding 3 (owner decision): resend whatever
            // was sent but never confirmed finalized by the OLD socket
            // FIRST, before the outage buffer - both are just "audio the
            // new socket has never seen", but this one is what the open
            // segment's stale non-final tail (already dropped, per finding
            // 6) belongs to, so it must be re-recognised before anything
            // captured strictly later in time.
            resendUnfinalizedAudioIfAny()
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
            trimFinalizedAudio(finalAudioProcMs: response.finalAudioProcMs)
            guard let engine = joinEngine else { return }
            engine.applyStreamM(response.tokens)
            onSegmentsChanged?(engine.segments)
        case .closed:
            guard !isEnding else { return }
            if let completion = pendingStartCompletion {
                pendingStartCompletion = nil
                // Review round 4, finding 1: an INITIAL connect failure
                // (never yet reached `.configSent`) must close this socket
                // right here too - without this, `self.socket` kept
                // pointing at a socket nothing had told to close, and
                // `LiveSessionController`'s own follow-up `end{}` was the
                // only thing that eventually closed it (1.5 s later via the
                // graceful sequence) - fine on its own, but one more
                // reachable path where a socket could be left open longer
                // than necessary.
                socket?.close()
                socket = nil
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
        // Routed through the same tracking as any other send, so this
        // audio also becomes resendable (finding 3) if THIS socket drops
        // again before Soniox finalizes it.
        for chunk in bufferedAudio {
            sendAndTrackAudio(chunk)
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
        reconnectScheduleToken += 1
        let token = reconnectScheduleToken
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.reconnectScheduleToken == token, self.isReconnecting, !self.isEnding else { return }
            self.connectFresh()
        }
    }

    /// Review round 4, finding 4a (owner decision): reconnect the instant
    /// iOS reports the network path is available again, rather than
    /// waiting out whatever backoff delay is still pending - preserving
    /// the single-pending-attempt and max-one-connection guarantees the
    /// same way a normal retry does. Does NOT reset `reconnectAttempt`: a
    /// flapping network reporting "available" repeatedly must not reset
    /// backoff to its shortest delay every time, only genuinely skip the
    /// CURRENT wait once.
    ///
    /// Review round 5, finding C6 (blocking): also requires `socket == nil`
    /// - `isReconnecting` alone stays `true` for the WHOLE reconnect saga,
    /// including while a socket already exists and is mid-handshake,
    /// waiting for its own `.configSent` or failure. Without this, a path
    /// event arriving during that window aborted the in-flight attempt and
    /// started a new one instead of letting it run its course - the
    /// reviewer's own reproduction: one backoff attempt plus two path
    /// events created four sockets. `socket == nil` is true only during the
    /// genuine "waiting for backoff, nothing in flight yet" gap - the only
    /// moment this should ever preempt.
    private func handlePathAvailable() {
        guard isReconnecting, !isEnding, socket == nil else { return }
        reconnectScheduleToken += 1 // invalidate whatever backoff timer is still pending
        connectFresh()
    }

    /// Opens a brand-new socket against the current `config` and wires it
    /// back into `handle`, stamped with a freshly-incremented generation so
    /// any lingering event from a superseded socket is discarded rather
    /// than mistaken for this socket's own status. Used both for the
    /// initial connect and for every reconnect/retry attempt.
    private func connectFresh() {
        guard let config else { return }
        // Review round 4, finding 1: defensive, belt-and-suspenders
        // invariant - NEVER let a previously-tracked socket go unreferenced
        // without being told to close first, no matter what path led here.
        // Every other fix in this method's surrounding code is meant to
        // make `self.socket` already `nil` by the time this runs; this is
        // what makes "at most one open connection" hold even if some future
        // change reintroduces a path that forgets to.
        socket?.close()
        connectionGeneration += 1
        let generation = connectionGeneration
        let epoch = sessionEpoch
        // A brand-new socket's own `final_audio_proc_ms` starts back at 0,
        // so the watermark it is compared against must too (finding B2) -
        // `unfinalizedSentAudio` itself is NOT cleared here (finding 3):
        // it is what survives a drop to be resent to this new socket.
        finalizedByteWatermark = 0
        sessionConnectionAttempt += 1
        lifecycleLogger.log("session #\(self.sessionId, privacy: .public) opening connection attempt #\(self.sessionConnectionAttempt, privacy: .public) of this session")

        var hints = [config.meLanguage, config.targetLanguage]
        if let guestHint = config.guestHint { hints.append(guestHint) }

        let newSocket = makeSocket()
        // Labels the one-shot translation_status wire-shape diagnostic
        // only (see `SonioxStreamSocket`) - a no-op for a test's fake,
        // which never conforms to the concrete adapter type.
        (newSocket as? SonioxStreamSocket)?.streamLabel = "M"
        socket = newSocket

        newSocket.onEvent = { [weak self] event in self?.handle(event, generation: generation, epoch: epoch) }

        newSocket.connect(apiKey: config.apiKey, languageHints: hints, targetLanguage: config.meLanguage)
    }

    // MARK: - On-device me -> target translation

    func setTranslationAvailable(_ available: Bool) {
        isTranslationAvailable = available
    }

    /// Only `.installed` at session start (`isTranslationAvailable`) ever
    /// enqueues - the primary gate from docs/soniox-routing.md. This alone
    /// does not cover every case (availability is only rechecked at session
    /// start, and a request already enqueued before it flips can still sit
    /// in the queue's stream buffer) - `reportTranslationStarted`'s `Bool`
    /// return is the second, authoritative gate the consuming closure must
    /// obey before ever calling `translate`.
    private func enqueueMeTranslation(segmentId: Int, source: String) {
        guard isTranslationAvailable else { return }
        let requestId = nextTranslationRequestId
        nextTranslationRequestId += 1
        translationRequestSegmentId[requestId] = segmentId
        translationQueue.enqueue(id: requestId, source: source)
    }

    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)> {
        translationQueue.makeRequests()
    }

    func reportTranslationStarted(id: Int) -> Bool {
        guard let segmentId = translationRequestSegmentId[id] else { return false }
        guard isTranslationAvailable else {
            // Availability dropped (or was never confirmed) between this
            // request being enqueued and the closure reaching it - treat
            // exactly like any other abandonment: no translate call, no
            // indicator, never retried.
            translationRequestSegmentId.removeValue(forKey: id)
            translationQueue.finished(id: id)
            joinEngine?.applyTranslationFailure(segmentId: segmentId)
            if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
            return false
        }
        joinEngine?.applyTranslationStarted(segmentId: segmentId)
        if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
        return true
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
