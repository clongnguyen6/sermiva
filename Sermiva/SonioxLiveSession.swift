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

    /// A unique id for this OBJECT (it persists across "Phiên mới", like the
    /// object itself), carried by every connection-lifecycle line this
    /// session and its sockets log - see `ConnectionLifecycleLogging.swift`.
    let sessionId = LifecycleIds.session.next()

    /// What the connection is doing. Every lifecycle event is decided by
    /// `phase` alone, in `handle` and the handful of methods it calls - the
    /// one place that decides transitions (docs/soniox-routing.md,
    /// "Connection lifecycle").
    private enum ConnectionPhase {
        /// No session, or the session's connection has fully closed.
        case inactive
        /// The first connection of a session is in flight; `start`'s
        /// completion is still pending.
        case starting
        /// `socket` has accepted its config; audio goes to it live.
        case streaming
        /// No established connection: `socket` is `nil` while a backoff
        /// timer is pending, or an attempt still in flight.
        case reconnecting
        /// `end()` sent finalize to the established `socket`; what it still
        /// returns (the `<fin>` answer) is applied until it closes.
        case ending
    }

    private var phase: ConnectionPhase = .inactive
    private var config: SonioxSessionConfig?
    /// The session's one socket, in whatever state `phase` says. Events
    /// from any other socket object are stale (see `handle`) - each socket
    /// object is used for exactly one connection attempt.
    private var socket: SonioxSocketConnecting?
    private var joinEngine: SonioxJoinEngine?
    /// Review round 4, finding 4a (owner decision): reconnect the instant
    /// iOS reports the network path is available again, instead of waiting
    /// out backoff. Created in `start(config:)`, cancelled as soon as the
    /// session stops - a session-lifetime resource, like the keepalive.
    private var pathMonitor: NetworkPathMonitoring?

    /// Persists across "Phiên mới" (this object is reused, only
    /// `joinEngine` is recreated) purely so translation request ids never
    /// repeat - see `enqueueMeTranslation` and `translationRequests`
    /// below for why that is what keeps a stale, still-in-flight on-device
    /// translation from a just-ended session from ever landing on a
    /// same-numbered segment in the next one.
    private let translationQueue = MeTranslationQueue()
    private var nextTranslationRequestId = 1
    /// Which segment, of which session (`sessionEpoch`), each on-device
    /// translation request was made for. A report for a request from any
    /// other session is dropped here, so a late result can never land on a
    /// later session's same-numbered segment, whatever the queue still holds.
    private var translationRequests: [Int: (sessionEpoch: Int, segmentId: Int)] = [:]
    /// Documented choice (c), awaiting the owner's decision: a `me` segment
    /// that only the `<fin>` answer after Kết thúc finalizes is not sent to
    /// on-device translation. Flipping this to `true` is the whole change
    /// for the recommended alternative: such a segment is then enqueued
    /// while the connection closes, translated after Kết thúc (the
    /// indicator only shows while the screen is running, so none shows
    /// then), and abandoned at "Phiên mới" (`start` abandons whatever is
    /// left; the session-epoch guard above keeps any late result off the
    /// next session's segments).
    static let translatesSegmentsFinalizedAfterEnd = false
    /// Set by `LiveSessionController` via `setTranslationAvailable` once its
    /// own per-session availability check resolves. `false` by default and
    /// reset at every `start()` - fail closed until explicitly confirmed, so
    /// nothing is ever enqueued/translated on a guess while that check is
    /// still in flight. See docs/soniox-routing.md.
    private var isTranslationAvailable = false

    /// Audio captured while no connection is established (the first
    /// connect, or an outage), sent once one is. Holds exactly the most
    /// recent 60 s of the converted 16 kHz mono Int16 stream (32,000
    /// bytes/s) - the oldest audio beyond that is dropped, down to the byte.
    private var bufferedAudio: [Data] = []
    private var bufferedAudioByteCount = 0
    private let bufferedAudioMaxBytes = 60 * 32_000
    /// Review round 4, finding 3 (owner decision): the audio the CURRENT
    /// connection has received but its server has not yet confirmed
    /// finalized (`final_audio_proc_ms`) - resent to the next connection
    /// FIRST, before `bufferedAudio`, if this one drops. Always a contiguous
    /// tail of what this connection received, starting at stream position
    /// `unfinalizedStartByte`: finalization and the 15 s bound both only
    /// ever move that start forward, so it holds exactly
    /// `[max(finalized, sent - 15 s), sent)` - see `trimFinalizedAudio`.
    private var unfinalizedSentAudio: [Data] = []
    private var unfinalizedSentAudioByteCount = 0
    private let unfinalizedSentAudioMaxBytes = 15 * 32_000
    /// Review, 54b3202 finding 3: the byte position, within the current
    /// connection's own audio stream, of the first byte still in
    /// `unfinalizedSentAudio`. The 15 s bound drops from the front of the
    /// buffer, so the front is NOT always the confirmed position - round 5
    /// assumed it was, and trimmed confirmed audio from wherever the front
    /// happened to be, skipping audio that was never finalized.
    private var unfinalizedStartByte = 0

    /// Bumped at every `start()`. `.authRejected` is checked against this,
    /// not socket identity: auth wins from any socket this session opened,
    /// including one already superseded, until the session has fully
    /// closed - but never leaks into a later session reusing this object.
    private var sessionEpoch = 0
    /// Review round 4, finding 1: how many connection attempts THIS session
    /// (since the last `start()`) has made - purely a logging aid.
    private var sessionConnectionAttempt = 0
    /// Attempts scheduled since a server last ANSWERED on a connection.
    /// Review of 2046102, item 5: reset only by the first response on a
    /// connection - Soniox sends no explicit "config accepted" message, and
    /// the socket reporting its config SENT proves nothing about the server
    /// accepting it. A server that takes the config, errors, and closes must
    /// keep backing off, not reconnect every second forever.
    private var reconnectAttempt = 0
    private var hasAnsweredOnThisConnection = false
    private let reconnectBaseDelay: TimeInterval = 1
    private let reconnectMaxDelay: TimeInterval = 30
    /// Per HANDOFF section 6, retry/backoff is a `reconnecting` (mid-
    /// session) behaviour; an initial connect failure is not retried here -
    /// `LiveSessionController` already gives the user their own retry via
    /// tapping Bắt đầu again.
    private var pendingStartCompletion: (@MainActor (Bool) -> Void)?
    private var pendingEndCompletion: (@MainActor () -> Void)?
    private let keepaliveInterval: TimeInterval = 10
    /// Each scheduled timer captures the token current when it was
    /// scheduled; bumping the token is how a timer is cancelled (the
    /// scheduler seam has no cancel). A stale timer that fires anyway does
    /// nothing.
    private var reconnectScheduleToken = 0
    private var closeScheduleToken = 0
    private var keepaliveScheduleToken = 0

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

    private func log(_ message: String) {
        lifecycleLogger.log("session #\(self.sessionId, privacy: .public) \(message, privacy: .public)")
    }

    /// The real socket's own id for the lifecycle log; test fakes have none.
    private func socketLabel(_ socket: SonioxSocketConnecting?) -> String {
        (socket as? SonioxStreamSocket).map { "socket #\($0.socketId)" } ?? "socket #?"
    }

    // MARK: - Session start

    func start(config: SonioxSessionConfig, completion: @escaping @MainActor (Bool) -> Void) {
        log("start() called in phase \(phase)")
        // "Phiên mới" can arrive while the previous session's connection is
        // still in its close window after Kết thúc. That transcript has just
        // been cleared, so its `<fin>` answer has nowhere to go - close it
        // now rather than hold a second metered connection open.
        let previousEndCompletion = pendingEndCompletion
        pendingEndCompletion = nil
        closeSocket()
        closeScheduleToken += 1
        reconnectScheduleToken += 1
        endPauseKeepalive()
        pathMonitor?.cancel()
        clearBufferedAudio()
        clearUnfinalizedSentAudio()
        previousEndCompletion?()

        self.config = config
        sessionEpoch += 1
        // Normally a no-op (`end` already abandoned the queue). Anything a
        // previous session still has queued belongs to another epoch, so
        // abandoning it touches no segment of the new session.
        translationQueue.abandonAll()
        phase = .starting
        reconnectAttempt = 0
        sessionConnectionAttempt = 0
        isTranslationAvailable = false
        let monitor = makePathMonitor()
        // A cancelled monitor's last callback can still be on its way (the
        // real one hops to the main actor): only the current monitor counts.
        monitor.onPathAvailable = { [weak self, weak monitor] in
            guard let self, let monitor, monitor === self.pathMonitor else { return }
            self.handlePathAvailable()
        }
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
        pendingStartCompletion = completion
        connectFresh()
    }

    // MARK: - Audio

    func ingestAudio(_ data: Data) {
        switch phase {
        case .streaming:
            sendAndTrackAudio(data)
        case .starting, .reconnecting:
            appendBufferedAudio(data)
        case .ending, .inactive:
            // The mic is already off by then (`LiveSessionController`);
            // nothing captured after Kết thúc is ever sent.
            break
        }
    }

    /// Every chunk sent to the current connection is also kept in
    /// `unfinalizedSentAudio` until its server confirms it finalized.
    private func sendAndTrackAudio(_ data: Data) {
        socket?.sendAudio(data)
        unfinalizedSentAudio.append(data)
        unfinalizedSentAudioByteCount += data.count
        let excess = unfinalizedSentAudioByteCount - unfinalizedSentAudioMaxBytes
        if excess > 0 {
            Self.dropFront(excess, of: &unfinalizedSentAudio, count: &unfinalizedSentAudioByteCount)
            unfinalizedStartByte += excess
        }
    }

    /// `final_audio_proc_ms` is CUMULATIVE for the connection (round 5,
    /// finding B2), so it is a stream POSITION: everything before it is
    /// finalized. Drops exactly the part of `unfinalizedSentAudio` that lies
    /// before that position - never more, whatever the 15 s bound already
    /// dropped - splitting the one chunk that straddles it.
    private func trimFinalizedAudio(finalAudioProcMs: Int) {
        let sentByte = unfinalizedStartByte + unfinalizedSentAudioByteCount
        let finalizedByte = min((finalAudioProcMs * 32_000) / 1000, sentByte)
        let newlyFinalized = finalizedByte - unfinalizedStartByte
        guard newlyFinalized > 0 else { return }
        Self.dropFront(newlyFinalized, of: &unfinalizedSentAudio, count: &unfinalizedSentAudioByteCount)
        unfinalizedStartByte = finalizedByte
    }

    private func clearUnfinalizedSentAudio() {
        unfinalizedSentAudio = []
        unfinalizedSentAudioByteCount = 0
        unfinalizedStartByte = 0
    }

    private func appendBufferedAudio(_ data: Data) {
        bufferedAudio.append(data)
        bufferedAudioByteCount += data.count
        let excess = bufferedAudioByteCount - bufferedAudioMaxBytes
        if excess > 0 {
            Self.dropFront(excess, of: &bufferedAudio, count: &bufferedAudioByteCount)
        }
    }

    private func clearBufferedAudio() {
        bufferedAudio = []
        bufferedAudioByteCount = 0
    }

    /// Removes exactly `bytes` from the front of `chunks`, splitting the
    /// chunk that straddles the cut. Every cut this class makes is a whole
    /// number of 16-bit samples: the bounds and ms positions are all
    /// multiples of 32 bytes, applied to a stream of whole samples.
    private static func dropFront(_ bytes: Int, of chunks: inout [Data], count: inout Int) {
        var remaining = min(bytes, count)
        count -= remaining
        while remaining > 0, let first = chunks.first {
            if first.count <= remaining {
                remaining -= first.count
                chunks.removeFirst()
            } else {
                chunks[0] = Data(first.dropFirst(remaining))
                remaining = 0
            }
        }
    }

    // MARK: - Pause

    /// Every 10 s while paused, through the same scheduler as every other
    /// timer here, so a stopped keepalive (a token bump) can never fire
    /// again - not after Kết thúc, an auth rejection, or into a later session.
    func beginPauseKeepalive() {
        keepaliveScheduleToken += 1
        scheduleKeepalive(token: keepaliveScheduleToken)
    }

    func endPauseKeepalive() {
        keepaliveScheduleToken += 1
    }

    private func scheduleKeepalive(token: Int) {
        scheduler.schedule(after: keepaliveInterval) { [weak self] in
            guard let self, self.keepaliveScheduleToken == token else { return }
            self.sendKeepaliveIfStreaming()
            self.scheduleKeepalive(token: token)
        }
    }

    /// Keepalive only means something on an established connection; while
    /// reconnecting there is none, and the next one is kept alive from the
    /// moment it is established, since the timer keeps running.
    private func sendKeepaliveIfStreaming() {
        guard phase == .streaming else { return }
        socket?.sendKeepalive()
    }

    // MARK: - End

    /// The docs' end sequence: finalize, an empty frame, then close once the
    /// server is done or a timeout passes. Until the connection closes, what
    /// it returns - the `<fin>` answer - is applied like any other response
    /// (review of 54b3202, finding 4: round 5 discarded it, leaving the last
    /// utterance an unfinished draft). With no established connection
    /// there is nothing to finalize: whatever is still in flight closes now.
    func end(completion: @escaping @MainActor () -> Void) {
        if phase == .ending {
            let earlier = pendingEndCompletion
            pendingEndCompletion = { earlier?(); completion() }
            return
        }
        guard phase != .inactive else {
            completion()
            return
        }
        log("end() called in phase \(phase)")
        stopSessionActivities()
        pendingEndCompletion = completion
        guard phase == .streaming, let socketToFinalize = socket else {
            finishClosing()
            return
        }
        phase = .ending
        socketToFinalize.sendFinalize()
        socketToFinalize.sendEmptyFrame()
        // The docs' end sequence waits for `finished`, then closes; this
        // app is not the one that gets to hold a metered stream open
        // indefinitely waiting for it, so a short window stands in for that
        // wait, and `close()` always runs after it either way.
        closeScheduleToken += 1
        let token = closeScheduleToken
        scheduler.schedule(after: 1.5) { [weak self] in
            guard let self, self.closeScheduleToken == token, self.phase == .ending else { return }
            self.finishClosing()
        }
    }

    func endImmediately(completion: @escaping @MainActor () -> Void) {
        guard phase != .inactive else {
            completion()
            return
        }
        log("endImmediately() called in phase \(phase)")
        stopSessionActivities()
        finishClosing()
        completion()
    }

    /// Everything a running session owns except its socket: no reconnect,
    /// keepalive or path event may act after this, no buffered audio is
    /// sent anywhere, and on-device translation still queued or in flight
    /// is abandoned (`MeTranslationQueue.abandonAll` - the queue's own
    /// stream lives on for the next session, per fatalError rule 3).
    private func stopSessionActivities() {
        reconnectScheduleToken += 1
        endPauseKeepalive()
        pathMonitor?.cancel()
        pathMonitor = nil
        pendingStartCompletion = nil
        clearBufferedAudio()
        clearUnfinalizedSentAudio()
        translationQueue.abandonAll()
    }

    /// The session's connection is gone for good. M-direct translations
    /// still in progress are abandoned here rather than at `end()`, since
    /// the `<fin>` answer arriving before this may still complete them.
    private func finishClosing() {
        closeSocket()
        phase = .inactive
        closeScheduleToken += 1
        joinEngine?.abandonMDirectTranslationsInProgress()
        if let engine = joinEngine {
            onSegmentsChanged?(engine.segments)
        }
        let completion = pendingEndCompletion
        pendingEndCompletion = nil
        completion?()
    }

    private func closeSocket() {
        guard let closing = socket else { return }
        log("closing \(socketLabel(closing)) in phase \(phase)")
        closing.close()
        socket = nil
    }

    // MARK: - Connection events

    private func handle(_ event: SonioxSocketEvent, from eventSocket: SonioxSocketConnecting?, epoch: Int) {
        // Auth wins - from any socket this session opened, including one
        // already superseded or closed, as long as the session has not
        // fully closed yet (the window after Kết thúc included). Never from
        // a previous session reusing this object ("Phiên mới").
        if case .authRejected = event {
            guard epoch == sessionEpoch, phase != .inactive else { return }
            log("auth rejected by \(socketLabel(eventSocket)) in phase \(phase)")
            onAuthError?()
            return
        }
        // Anything else only ever counts from the session's current socket:
        // a superseded or already-closed one is stale by identity.
        guard let eventSocket, eventSocket === socket else { return }
        switch event {
        case .authRejected:
            break // handled above
        case .configSent:
            switch phase {
            case .starting:
                beginStreaming()
                let completion = pendingStartCompletion
                pendingStartCompletion = nil
                completion?(true)
            case .reconnecting:
                beginStreaming()
                onReconnected?()
            case .streaming, .ending, .inactive:
                break
            }
        case .response(let response):
            guard phase == .streaming || phase == .ending else { return }
            if phase == .streaming {
                if !hasAnsweredOnThisConnection {
                    // The server answered: the connection really works, so
                    // backoff starts over (see `reconnectAttempt`).
                    hasAnsweredOnThisConnection = true
                    reconnectAttempt = 0
                }
                trimFinalizedAudio(finalAudioProcMs: response.finalAudioProcMs)
            }
            guard let engine = joinEngine else { return }
            engine.applyStreamM(response.tokens)
            onSegmentsChanged?(engine.segments)
        case .closed:
            switch phase {
            case .starting:
                // A failed FIRST connection is not retried here (HANDOFF
                // section 6): the session stops, and the controller shows
                // "Lỗi mạng, thử lại sau" so the user can retry.
                log("\(socketLabel(eventSocket)) failed before connecting")
                let completion = pendingStartCompletion
                stopSessionActivities()
                closeSocket()
                phase = .inactive
                completion?(false)
            case .streaming:
                handleDrop()
            case .reconnecting:
                log("\(socketLabel(eventSocket)) failed before connecting")
                closeSocket()
                scheduleReconnectAttempt()
            case .ending:
                finishClosing()
            case .inactive:
                break
            }
        }
    }

    /// A connection accepted its config: resend what the previous one never
    /// confirmed finalized, then the outage buffer, then stream live.
    private func beginStreaming() {
        log("\(socketLabel(socket)) streaming")
        phase = .streaming
        hasAnsweredOnThisConnection = false
        // The resent audio is the start of this connection's own stream.
        unfinalizedStartByte = 0
        for chunk in unfinalizedSentAudio {
            socket?.sendAudio(chunk)
        }
        let outage = bufferedAudio
        clearBufferedAudio()
        for chunk in outage {
            sendAndTrackAudio(chunk)
        }
    }

    /// An established connection dropped. The open segment is closed like a
    /// genuine `<end>` (only if it has final text), and captured audio keeps
    /// accumulating in `bufferedAudio` across every attempt of the outage.
    private func handleDrop() {
        log("\(socketLabel(socket)) dropped")
        closeSocket()
        phase = .reconnecting
        joinEngine?.closeOpenSegmentForReconnect()
        joinEngine?.abandonMDirectTranslationsInProgress()
        joinEngine?.handleStreamMReconnected()
        if let engine = joinEngine {
            onSegmentsChanged?(engine.segments)
        }
        scheduleReconnectAttempt()
        onDisconnected?()
    }

    /// HANDOFF section 6: "retry backoff". Doubles from `reconnectBaseDelay`
    /// up to `reconnectMaxDelay`, resetting once a connection is
    /// established again.
    private func scheduleReconnectAttempt() {
        let delay = min(reconnectMaxDelay, reconnectBaseDelay * pow(2, Double(reconnectAttempt)))
        reconnectAttempt += 1
        reconnectScheduleToken += 1
        let token = reconnectScheduleToken
        scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.reconnectScheduleToken == token, self.phase == .reconnecting, self.socket == nil else { return }
            self.connectFresh()
        }
    }

    /// Review round 4, finding 4a (owner decision): reconnect the instant
    /// iOS reports the network path is available again, rather than
    /// waiting out whatever backoff delay is still pending. Only preempts a
    /// genuine wait - never an attempt already in flight (round 5, finding
    /// C6) - and does NOT reset `reconnectAttempt`, so a flapping network
    /// cannot reset backoff to its shortest delay every time.
    private func handlePathAvailable() {
        guard phase == .reconnecting, socket == nil else { return }
        log("network path available while waiting to reconnect")
        reconnectScheduleToken += 1 // invalidate the pending backoff timer
        connectFresh()
    }

    /// Opens a brand-new socket against the current `config`. Used both for
    /// the initial connect and for every reconnect attempt; `socket` is
    /// always `nil` by then.
    private func connectFresh() {
        guard let config else { return }
        closeSocket()
        let epoch = sessionEpoch
        sessionConnectionAttempt += 1

        var hints = [config.meLanguage, config.targetLanguage]
        if let guestHint = config.guestHint { hints.append(guestHint) }

        let newSocket = makeSocket()
        // Labels for the lifecycle log and the one-shot translation_status
        // wire-shape diagnostic (see `SonioxStreamSocket`) - a no-op for a
        // test's fake, which never conforms to the concrete adapter type.
        (newSocket as? SonioxStreamSocket)?.setLogLabels(streamLabel: "M", sessionId: sessionId)
        socket = newSocket
        log("opening connection attempt #\(sessionConnectionAttempt) of this session on \(socketLabel(newSocket))")

        newSocket.onEvent = { [weak self, weak newSocket] event in
            self?.handle(event, from: newSocket, epoch: epoch)
        }

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
    ///
    /// A segment finalized after Kết thúc (by the `<fin>` answer, while the
    /// connection closes) is not enqueued - see
    /// `translatesSegmentsFinalizedAfterEnd`.
    private func enqueueMeTranslation(segmentId: Int, source: String) {
        guard isTranslationAvailable else { return }
        guard phase != .ending || Self.translatesSegmentsFinalizedAfterEnd else { return }
        let requestId = nextTranslationRequestId
        nextTranslationRequestId += 1
        translationRequests[requestId] = (sessionEpoch, segmentId)
        translationQueue.enqueue(id: requestId, source: source)
    }

    /// The segment `id` was made for - only if it belongs to the current
    /// session. A request from another session is forgotten here.
    private func currentSegmentId(forRequest id: Int, removing: Bool) -> Int? {
        guard let request = translationRequests[id] else { return nil }
        guard request.sessionEpoch == sessionEpoch else {
            translationRequests.removeValue(forKey: id)
            translationQueue.finished(id: id)
            return nil
        }
        if removing { translationRequests.removeValue(forKey: id) }
        return request.segmentId
    }

    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)> {
        translationQueue.makeRequests()
    }

    func reportTranslationStarted(id: Int) -> Bool {
        guard let segmentId = currentSegmentId(forRequest: id, removing: false) else { return false }
        guard isTranslationAvailable else {
            // Availability dropped (or was never confirmed) between this
            // request being enqueued and the closure reaching it - treat
            // exactly like any other abandonment: no translate call, no
            // indicator, never retried.
            translationRequests.removeValue(forKey: id)
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
        guard let segmentId = currentSegmentId(forRequest: id, removing: true) else { return }
        translationQueue.finished(id: id)
        joinEngine?.applyTranslationSuccess(segmentId: segmentId, target: target)
        if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
    }

    func reportTranslationFailure(id: Int) {
        guard let segmentId = currentSegmentId(forRequest: id, removing: true) else { return }
        translationQueue.finished(id: id)
        joinEngine?.applyTranslationFailure(segmentId: segmentId)
        if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
    }

    private func handleTranslationAbandoned(requestId: Int) {
        guard let segmentId = currentSegmentId(forRequest: requestId, removing: true) else { return }
        joinEngine?.applyTranslationFailure(segmentId: segmentId)
        if let engine = joinEngine { onSegmentsChanged?(engine.segments) }
    }
}
