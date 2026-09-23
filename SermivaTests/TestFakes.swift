import Foundation
import Translation
@testable import Sermiva

/// Answers a mic-permission request synchronously with a fixed, injected
/// result instead of showing a real system alert. `granted` is mutable so a
/// test can simulate the user granting access via iPhone Settings between
/// two taps of the main button.
final class FakeMicPermissionProvider: MicPermissionProviding {
    var granted: Bool
    private(set) var requestCount = 0

    init(granted: Bool) {
        self.granted = granted
    }

    @MainActor func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        requestCount += 1
        completion(granted)
    }
}

/// Tracks start/stop calls instead of touching real audio hardware.
/// `failNextStart` lets a test simulate the engine failing to open.
/// `simulateExternalStop()` lets a test simulate capture stopping itself for
/// a reason outside an explicit `stop()` call (backgrounding, interruption).
final class FakeAudioCapture: AudioCapturing {
    enum CaptureError: Error { case simulatedFailure }

    private(set) var startCount = 0
    private(set) var stopCount = 0
    var failNextStart = false
    var onUnexpectedStop: (@MainActor () -> Void)?
    var onAudioBuffer: (@MainActor (Data) -> Void)?

    func start() throws {
        if failNextStart {
            failNextStart = false
            throw CaptureError.simulatedFailure
        }
        startCount += 1
    }

    func stop() {
        stopCount += 1
    }

    @MainActor func simulateExternalStop() {
        onUnexpectedStop?()
    }
}

/// Stands in for `SonioxLiveSession` so `LiveSessionController`'s state
/// machine is testable without ever opening a socket. `start` never
/// connects to anything real - the test drives its `completion` and the
/// `on...` callbacks directly to simulate what a real session would report.
final class FakeSonioxLiveSession: SonioxLiveSessionProtocol {
    var onSegmentsChanged: (@MainActor ([Segment]) -> Void)?
    var onAuthError: (@MainActor () -> Void)?
    var onDisconnected: (@MainActor () -> Void)?
    var onReconnected: (@MainActor () -> Void)?

    private(set) var startCount = 0
    private(set) var endCount = 0
    private(set) var endImmediatelyCount = 0
    private(set) var ingestedAudioCount = 0
    private(set) var pauseKeepaliveCount = 0
    private(set) var resumeCount = 0
    var nextStartResult = true
    /// When `false`, `start`'s `completion` is stored instead of called
    /// immediately, so a test can control exactly when the connect attempt
    /// "settles" relative to other async work (e.g. the translation
    /// availability check) - see `completeStart`.
    var completesImmediately = true
    private var pendingStartCompletion: (@MainActor (Bool) -> Void)?

    // See SonioxLiveSession.init for why this must be nonisolated.
    nonisolated init() {}

    func start(config: SonioxSessionConfig, completion: @escaping @MainActor (Bool) -> Void) {
        startCount += 1
        if completesImmediately {
            completion(nextStartResult)
        } else {
            pendingStartCompletion = completion
        }
    }

    /// Fires a `start` completion previously withheld via
    /// `completesImmediately = false`.
    func completeStart(ok: Bool) {
        let completion = pendingStartCompletion
        pendingStartCompletion = nil
        completion?(ok)
    }

    func ingestAudio(_ data: Data) {
        ingestedAudioCount += 1
    }

    func beginPauseKeepalive() {
        pauseKeepaliveCount += 1
    }

    func endPauseKeepalive() {
        resumeCount += 1
    }

    func end(completion: @escaping @MainActor () -> Void) {
        endCount += 1
        completion()
    }

    func endImmediately(completion: @escaping @MainActor () -> Void) {
        endImmediatelyCount += 1
        completion()
    }

    private(set) var makeTranslationRequestsCallCount = 0
    private(set) var reportedTranslationStarted: [Int] = []
    private(set) var reportedTranslationSuccess: [(id: Int, target: String)] = []
    private(set) var reportedTranslationFailure: [Int] = []
    private(set) var translationAvailableHistory: [Bool] = []
    var nextReportTranslationStartedResult = true

    func setTranslationAvailable(_ available: Bool) {
        translationAvailableHistory.append(available)
    }

    func makeTranslationRequests() -> AsyncStream<(id: Int, source: String)> {
        makeTranslationRequestsCallCount += 1
        return AsyncStream { $0.finish() }
    }

    func reportTranslationStarted(id: Int) -> Bool {
        reportedTranslationStarted.append(id)
        return nextReportTranslationStartedResult
    }

    func reportTranslationSuccess(id: Int, target: String) {
        reportedTranslationSuccess.append((id, target))
    }

    func reportTranslationFailure(id: Int) {
        reportedTranslationFailure.append(id)
    }
}

/// Stands in for Apple's `LanguageAvailability`/language resolution behind
/// `MeToTargetAvailabilityChecking`, so `LiveSessionControllerTests` can
/// drive `LiveSessionController`'s gate/banner/config-once logic with a
/// controlled status instead of the real (Simulator-unavailable) framework.
final class FakeMeToTargetAvailabilityChecker: MeToTargetAvailabilityChecking {
    var source = Locale.Language(identifier: "vi")
    var target = Locale.Language(identifier: "en-US")
    var nextStatus: LanguageAvailability.Status = .installed
    private(set) var statusCallCount = 0
    /// When `true`, `status(from:to:)` suspends until `resumeOldestHeldStatus()`
    /// is called - lets a test control exactly when one specific call
    /// resolves, in FIFO order, to reproduce cross-attempt ordering races.
    var holdStatus = false
    private var pendingContinuations: [CheckedContinuation<Void, Never>] = []

    func resolveLanguages() async -> (source: Locale.Language, target: Locale.Language) {
        (source, target)
    }

    func status(from source: Locale.Language, to target: Locale.Language) async -> LanguageAvailability.Status {
        statusCallCount += 1
        if holdStatus {
            await withCheckedContinuation { continuation in
                pendingContinuations.append(continuation)
            }
        }
        return nextStatus
    }

    /// Resumes the OLDEST still-held `status` call - the first one to have
    /// started waiting.
    func resumeOldestHeldStatus() {
        guard !pendingContinuations.isEmpty else { return }
        pendingContinuations.removeFirst().resume()
    }
}

/// Records scheduled actions instead of waiting on a real clock, so tests
/// control exactly how far playback advances.
final class ManualScheduler: DemoScheduler {
    private(set) var pending: [() -> Void] = []

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) {
        pending.append(action)
    }

    /// Runs exactly the actions queued so far - not ones they schedule.
    func drainOnce() {
        let toRun = pending
        pending.removeAll()
        toRun.forEach { $0() }
    }

    /// Runs every pending action, including ones scheduled while draining,
    /// until the queue is empty.
    func drainAll(maxIterations: Int = 10_000) {
        var iterations = 0
        while !pending.isEmpty {
            iterations += 1
            precondition(iterations < maxIterations, "scheduler did not settle")
            drainOnce()
        }
    }
}

/// Stands in for one Soniox socket at the `SonioxSocketConnecting` seam -
/// app-owned lifecycle events only, never Soniox JSON or a real
/// `URLSessionWebSocketTask` - so `SonioxLiveSession`'s reconnect/retry
/// policy is testable without ever going through `SonioxStreamSocket`. A
/// test drives the server side by calling `simulateConfigSent()` etc.
/// directly on whichever fake `FakeSonioxSocketFactory` handed out.
@MainActor
final class FakeSonioxSocketConnection: SonioxSocketConnecting {
    var onEvent: ((SonioxSocketEvent) -> Void)?
    private(set) var connectCount = 0
    private(set) var sentAudioChunks: [Data] = []
    private(set) var lastApiKey: String?
    private(set) var lastLanguageHints: [String]?
    private(set) var lastTargetLanguage: String?
    // `nonisolated(unsafe)` so `close()` can update this synchronously from
    // a nonisolated context, matching the real `SonioxStreamSocket.close()`
    // this fake stands in for - tests only ever run single-threaded on the
    // main actor, so there is no real concurrent access to guard against.
    nonisolated(unsafe) private(set) var closeCount = 0
    var isClosed: Bool { closeCount > 0 }

    func connect(apiKey: String, languageHints: [String], targetLanguage: String) {
        connectCount += 1
        lastApiKey = apiKey
        lastLanguageHints = languageHints
        lastTargetLanguage = targetLanguage
    }

    func sendAudio(_ data: Data) {
        sentAudioChunks.append(data)
    }

    func sendKeepalive() {}
    func sendFinalize() {}
    func sendEmptyFrame() {}

    nonisolated func close() {
        closeCount += 1
    }

    func simulateConfigSent() {
        onEvent?(.configSent)
    }

    func simulateAuthRejected() {
        onEvent?(.authRejected)
    }

    func simulateResponse(tokens: [SonioxToken] = [], finalAudioProcMs: Int = 0) {
        onEvent?(.response(SonioxSocketResponse(tokens: tokens, finalAudioProcMs: finalAudioProcMs)))
    }

    func simulateClosed(_ error: Error? = nil) {
        onEvent?(.closed(error))
    }
}

/// Hands out a fresh `FakeSonioxSocketConnection` on every call, in the
/// same order `SonioxLiveSession.connectFresh` creates them (one per
/// connect/reconnect attempt) - so a test can index `createdSockets` to
/// reach any specific attempt's own socket.
@MainActor
final class FakeSonioxSocketFactory {
    private(set) var createdSockets: [FakeSonioxSocketConnection] = []

    func make() -> SonioxSocketConnecting {
        let socket = FakeSonioxSocketConnection()
        createdSockets.append(socket)
        return socket
    }
}
