import Combine
import XCTest
@testable import Sermiva

/// The connection-lifecycle invariant test (owner method: invariant first,
/// red on the current code for the right reason, then the fix).
///
/// Drives the REAL `LiveSessionController` + `SonioxLiveSession` through
/// fakes only: fake sockets at the `SonioxSocketConnecting` seam (app-owned
/// `SonioxSocketEvent`/`SonioxToken` values - no Soniox JSON, nothing
/// through `SonioxStreamSocket`, per AGENTS.md), a virtual clock behind
/// both `DemoScheduler`s, fake path monitors and fake audio capture.
///
/// A seeded generator produces event sequences; an oracle that tracks
/// ground truth on its own - which sockets are really open, which audio
/// was captured when, what each server has finalized - checks invariants
/// (a)-(g) below after every event. On a failure it shrinks the sequence
/// and prints the seed, the minimal sequence and a per-step trace.
///
/// Audio is encoded so every 1 ms unit (32 bytes of 16 kHz mono Int16)
/// carries its own capture index, which is how the oracle knows exactly
/// which captured audio each fake socket received. Server text is derived
/// from the same indices ("u<first>_<last>" for final text, "n..." for a
/// non-final tail), which is how it knows exactly which finalized text the
/// transcript must show.
///
/// Scale: `SERMIVA_FUZZ_SEEDS` / `SERMIVA_FUZZ_SEED_BASE` override the
/// committed count and base (pass them to xcodebuild prefixed with
/// `TEST_RUNNER_`). The committed values keep `./scripts/verify.sh` fast and
/// deterministic.
@MainActor
final class LifecycleInvariantTests: XCTestCase {
    private static let committedSeedCount = 400
    private static let committedSeedBase: UInt64 = 20_260_924

    func test_randomEventSequencesKeepEveryLifecycleInvariant() {
        let environment = ProcessInfo.processInfo.environment
        let count = environment["SERMIVA_FUZZ_SEEDS"].flatMap(Int.init) ?? Self.committedSeedCount
        let base = environment["SERMIVA_FUZZ_SEED_BASE"].flatMap(UInt64.init) ?? Self.committedSeedBase
        let started = Date()
        var firstFailureByKey: [String: (seed: UInt64, events: [LifecycleEvent])] = [:]
        var failingSeedsByKey: [String: Int] = [:]
        var failingSeeds = 0
        var totalEvents = 0
        for offset in 0..<count {
            let seed = base &+ UInt64(offset)
            let (events, violation) = LifecycleScenario.generateAndRun(seed: seed)
            totalEvents += events.count
            guard let violation else { continue }
            failingSeeds += 1
            failingSeedsByKey[violation.key, default: 0] += 1
            if firstFailureByKey[violation.key] == nil {
                firstFailureByKey[violation.key] = (seed, events)
            }
        }
        let seconds = Date().timeIntervalSince(started)
        print("LifecycleInvariantFuzz: \(count) seeds from base \(base), \(totalEvents) events, \(failingSeeds) failing seeds, \(String(format: "%.1f", seconds)) s")
        print("LifecycleInvariantFuzz coverage (scenarios reaching each interaction): " + LifecycleCoverage.summary())
        for key in firstFailureByKey.keys.sorted() {
            guard let first = firstFailureByKey[key] else { continue }
            let minimal = LifecycleScenario.minimize(first.events, key: key)
            let report = LifecycleScenario.report(minimal)
            XCTFail("\(key) - \(failingSeedsByKey[key] ?? 0) failing seed(s); first: seed \(first.seed)\n\(report)")
        }
    }

    // MARK: - The five reproductions from the review of 54b3202

    /// Finding 1: pause during reconnect; the connection comes back while
    /// paused; resume - must reach `.listening`, never stay `.reconnecting`.
    func test_named1_pauseDuringReconnectThenConnectionReturnsWhilePausedThenResume() {
        assertScenarioHolds([
            .tapPrimary, .connectSucceeds, .audio(ms: 500),
            .drop, .tapPrimary, .fireNextTimer, .connectSucceeds, .tapPrimary,
        ])
    }

    /// Finding 2: pause while listening; the connection drops while paused;
    /// resume - must show `.reconnecting`, never claim `.listening`.
    func test_named2_pauseWhileListeningThenDropWhilePausedThenResume() {
        assertScenarioHolds([
            .tapPrimary, .connectSucceeds, .audio(ms: 500),
            .tapPrimary, .drop, .tapPrimary,
        ])
    }

    /// Finding 3 (2 s confirmed): a 20 s outage, reconnect, Soniox confirms
    /// 2 s of it, the connection drops again - the resend must be exactly the
    /// last 15 s (seconds 6-20), not 8-20.
    func test_named3a_secondDropWhileCatchingUpResendsTheLast15SecondsNotFinalized_2sConfirmed() {
        assertScenarioHolds(twentySecondOutageThenSecondDrop(confirmedPermille: 100))
    }

    /// Finding 3 (15 s confirmed): same, with 15 s confirmed - the resend must
    /// be exactly seconds 16-20, not nothing.
    func test_named3b_secondDropWhileCatchingUpResendsTheLast15SecondsNotFinalized_15sConfirmed() {
        assertScenarioHolds(twentySecondOutageThenSecondDrop(confirmedPermille: 750))
    }

    /// Finding 4: what Soniox returns after Kết thúc (the `<fin>` answer to
    /// `finalize`) must be applied, not discarded as stale.
    func test_named4_finAnswerAfterEndIsApplied() {
        assertScenarioHolds([
            .tapPrimary, .connectSucceeds, .audio(ms: 1000),
            .response(finalPermille: 0, tailPermille: 1000, speaker: 1, english: false, endMarker: false),
            .confirmEnd, .finAnswer, .advance(ms: 2000),
        ])
    }

    private func twentySecondOutageThenSecondDrop(confirmedPermille: Int) -> [LifecycleEvent] {
        [.tapPrimary, .connectSucceeds, .drop]
            + Array(repeating: LifecycleEvent.audio(ms: 1000), count: 20)
            + [
                .fireNextTimer, .connectSucceeds,
                .response(finalPermille: confirmedPermille, tailPermille: 0, speaker: 1, english: false, endMarker: false),
                .drop, .fireNextTimer, .connectSucceeds,
            ]
    }

    private func assertScenarioHolds(_ events: [LifecycleEvent], file: StaticString = #filePath, line: UInt = #line) {
        let outcome = LifecycleScenario.run(events)
        if let violation = outcome.violation {
            XCTFail("\(violation.key)\n\(LifecycleScenario.report(events))", file: file, line: line)
            return
        }
        XCTAssertEqual(outcome.applied.count, events.count, "sanity: every scripted event must have been applicable\n\(LifecycleScenario.report(events))", file: file, line: line)
    }
}

// MARK: - Events

enum LifecycleEvent: CustomStringConvertible {
    /// Taps the primary button (Bắt đầu / Tạm dừng / Tiếp tục / Phiên mới).
    case tapPrimary
    /// Confirms Kết thúc in `EndSessionSheet`.
    case confirmEnd
    /// The microphone delivers `ms` milliseconds of audio.
    case audio(ms: Int)
    /// The in-flight connection attempt completes (config accepted).
    case connectSucceeds
    /// The in-flight connection attempt fails before its config is accepted.
    case connectFails
    /// The server drops an established connection.
    case drop
    /// A server response on the established connection: finalizes
    /// `finalPermille`/1000 of the audio it has not finalized yet, shows
    /// `tailPermille`/1000 of the rest as a non-final tail.
    case response(finalPermille: Int, tailPermille: Int, speaker: Int, english: Bool, endMarker: Bool)
    /// The server answers `finalize`: everything final, then `<fin>`.
    case finAnswer
    /// The server rejects the key (401/402/403) on the `pick`-th open socket.
    case authRejected(pick: Int)
    /// iOS reports the network path satisfied.
    case pathAvailable
    /// The network path goes away (no callback exists for this direction);
    /// `dropsConnections` also drops/fails whatever connection is open.
    case pathLost(dropsConnections: Bool)
    case advance(ms: Int)
    case fireNextTimer
    /// A late event from a socket the app already closed (a completion
    /// handler that hopped to the main actor after `close()`).
    case staleSocketEvent(kind: Int, pick: Int)
    /// A late "path satisfied" from an already-cancelled path monitor.
    case stalePathEvent

    var description: String {
        switch self {
        case .tapPrimary: return "tap primary button"
        case .confirmEnd: return "confirm Kết thúc"
        case .audio(let ms): return "mic delivers \(ms) ms"
        case .connectSucceeds: return "connection attempt succeeds (config accepted)"
        case .connectFails: return "connection attempt fails"
        case .drop: return "server drops the connection"
        case let .response(finalPermille, tailPermille, speaker, english, endMarker):
            return "server response: finalize \(finalPermille)‰ of unconfirmed, tail \(tailPermille)‰, speaker \(speaker), \(english ? "en" : "vi")\(endMarker ? ", <end>" : "")"
        case .finAnswer: return "server answers finalize (all final + <fin>)"
        case .authRejected(let pick): return "server rejects the key on open socket pick \(pick)"
        case .pathAvailable: return "network path available"
        case .pathLost(let drops): return "network path lost\(drops ? " (drops connections)" : "")"
        case .advance(let ms): return "time +\(ms) ms"
        case .fireNextTimer: return "next timer fires"
        case let .staleSocketEvent(kind, pick):
            let names = ["closed", "configSent", "response", "authRejected"]
            return "late \(names[kind % names.count]) from already-closed socket pick \(pick)"
        case .stalePathEvent: return "late path event from a cancelled monitor"
        }
    }
}

struct LifecycleViolation {
    let key: String
    let message: String
}

// MARK: - Scenario running, generation, shrinking

@MainActor
enum LifecycleScenario {
    struct Outcome {
        let violation: LifecycleViolation?
        let applied: [LifecycleEvent]
        let trace: [String]
    }

    static func run(_ events: [LifecycleEvent], traced: Bool = false) -> Outcome {
        let world = LifecycleWorld()
        var applied: [LifecycleEvent] = []
        var trace: [String] = []
        for event in events {
            guard world.apply(event) else { continue }
            applied.append(event)
            let violation = world.check()
            if traced {
                trace.append("\(applied.count). \(event) -> \(world.snapshot())")
            }
            if let violation {
                return Outcome(violation: violation, applied: applied, trace: trace)
            }
        }
        return Outcome(violation: nil, applied: applied, trace: trace)
    }

    static func generateAndRun(seed: UInt64) -> ([LifecycleEvent], LifecycleViolation?) {
        var rng = LifecycleRandom(seed: seed)
        let world = LifecycleWorld()
        world.recordsCoverage = true
        defer { LifecycleCoverage.add(world.coverage) }
        var events: [LifecycleEvent] = []
        let length = rng.int(20...160)
        var teardown: [LifecycleEvent] = [.confirmEnd, .fireNextTimer, .finAnswer, .advance(ms: 10_000)]
        for index in 0..<(length + teardown.count) {
            let event = index < length ? world.propose(&rng) : teardown.removeFirst()
            events.append(event)
            guard world.apply(event) else { continue }
            if let violation = world.check() {
                return (events, violation)
            }
        }
        return (events, nil)
    }

    /// Shrinks `events` while it still fails with the same invariant key:
    /// removes ever-smaller chunks, then single events, until nothing more
    /// can go.
    static func minimize(_ events: [LifecycleEvent], key: String) -> [LifecycleEvent] {
        func fails(_ candidate: [LifecycleEvent]) -> Bool {
            run(candidate).violation?.key == key
        }
        var current = run(events).applied
        guard fails(current) else { return events }
        var chunk = max(1, current.count / 2)
        while chunk >= 1 {
            var start = 0
            var removedAny = false
            while start < current.count {
                var candidate = current
                candidate.removeSubrange(start..<min(current.count, start + chunk))
                if fails(candidate) {
                    current = run(candidate).applied
                    removedAny = true
                } else {
                    start += chunk
                }
            }
            if !removedAny {
                if chunk == 1 { break }
                chunk = max(1, chunk / 2)
            }
        }
        return current
    }

    static func report(_ events: [LifecycleEvent]) -> String {
        let outcome = run(events, traced: true)
        var lines = ["minimal sequence (\(outcome.applied.count) events), state after each:"]
        lines += outcome.trace.map { "  " + $0 }
        if let violation = outcome.violation {
            lines.append("  VIOLATION \(violation.key): \(violation.message)")
        }
        return lines.joined(separator: "\n")
    }
}

struct LifecycleRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        range.lowerBound + Int(next() % UInt64(range.count))
    }

    mutating func chance(_ percent: Int) -> Bool {
        int(0...99) < percent
    }

    mutating func pick<T>(_ options: [T]) -> T {
        options[int(0...(options.count - 1))]
    }
}

// MARK: - Virtual time

final class LifecycleVirtualClock {
    private struct Pending {
        let due: Double
        let order: Int
        let action: () -> Void
    }

    private(set) var now: Double = 0
    private var pending: [Pending] = []
    private var order = 0

    func schedule(after seconds: Double, _ action: @escaping () -> Void) {
        order += 1
        pending.append(Pending(due: now + seconds, order: order, action: action))
    }

    var nextDue: Double? {
        earliestIndex().map { pending[$0].due }
    }

    /// Fires every timer due at or before `target`, in due order, including
    /// timers scheduled by the ones that fire.
    func advance(to target: Double) {
        while let index = earliestIndex(), pending[index].due <= target {
            let timer = pending.remove(at: index)
            now = max(now, timer.due)
            timer.action()
        }
        now = max(now, target)
    }

    private func earliestIndex() -> Int? {
        pending.indices.min { (pending[$0].due, pending[$0].order) < (pending[$1].due, pending[$1].order) }
    }
}

struct LifecycleClockScheduler: DemoScheduler {
    let clock: LifecycleVirtualClock

    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) {
        clock.schedule(after: seconds, action)
    }
}

// MARK: - Fakes

/// One Soniox connection at the `SonioxSocketConnecting` seam, plus the
/// server-side ground truth for it: whether it is really open, what audio
/// it received (decoded back to capture indices), and how much of that its
/// server has finalized.
@MainActor
final class LifecycleFakeSocket: SonioxSocketConnecting {
    let id: Int
    /// Which user session (Bắt đầu / Phiên mới) was current when the app
    /// created this socket.
    let userSession: Int
    var onEvent: ((SonioxSocketEvent) -> Void)?

    private(set) var connectCalled = false
    var configAccepted = false
    var dead = false
    nonisolated(unsafe) private(set) var closedByApp = false
    private(set) var received: [Int] = []
    private(set) var receivedChanged = false
    private(set) var misuse: String?
    /// How many ms of this connection's own audio stream its server has
    /// finalized (`final_audio_proc_ms`).
    var serverFinalizedMs = 0
    private(set) var finalizeRequested = false
    var answeredFinalize = false

    init(id: Int, userSession: Int) {
        self.id = id
        self.userSession = userSession
    }

    var isOpen: Bool { connectCalled && !dead && !closedByApp }
    var isEstablished: Bool { isOpen && configAccepted }
    var isHandshaking: Bool { isOpen && !configAccepted }

    func connect(apiKey: String, languageHints: [String], targetLanguage: String) {
        if connectCalled { misuse = misuse ?? "connect() called twice on socket #\(id)" }
        connectCalled = true
    }

    func sendAudio(_ data: Data) {
        guard isEstablished else {
            misuse = misuse ?? "audio sent to socket #\(id) while it was \(closedByApp ? "closed by the app" : dead ? "already dropped" : "not yet established")"
            return
        }
        guard data.count % LifecycleAudio.bytesPerUnit == 0 else {
            misuse = misuse ?? "socket #\(id) received a chunk of \(data.count) bytes, not a whole number of ms"
            return
        }
        received += LifecycleAudio.decode(data)
        receivedChanged = true
    }

    func sendKeepalive() {}

    func sendFinalize() {
        finalizeRequested = true
    }

    func sendEmptyFrame() {}

    nonisolated func close() {
        closedByApp = true
    }

    func clearChangeFlag() {
        receivedChanged = false
    }
}

@MainActor
final class LifecycleFakePathMonitor: NetworkPathMonitoring {
    var onPathAvailable: (() -> Void)?
    private(set) var started = false
    nonisolated(unsafe) private(set) var cancelled = false

    func start() {
        started = true
    }

    nonisolated func cancel() {
        cancelled = true
    }

    var isLive: Bool { started && !cancelled }
}

final class LifecycleFakeCapture: AudioCapturing {
    var onUnexpectedStop: (@MainActor () -> Void)?
    var onAudioBuffer: (@MainActor (Data) -> Void)?
    private(set) var isRunning = false

    func start() throws {
        isRunning = true
    }

    func stop() {
        isRunning = false
    }
}

struct LifecycleNetworkError: Error {}

enum LifecycleAudio {
    /// 1 ms of 16 kHz mono Int16.
    static let bytesPerUnit = 32

    static func encode(_ units: Range<Int>) -> Data {
        var data = Data(count: units.count * bytesPerUnit)
        data.withUnsafeMutableBytes { raw in
            for (offset, unit) in units.enumerated() {
                raw.storeBytes(of: UInt32(unit).littleEndian, toByteOffset: offset * bytesPerUnit, as: UInt32.self)
            }
        }
        return data
    }

    static func decode(_ data: Data) -> [Int] {
        data.withUnsafeBytes { raw in
            stride(from: 0, to: raw.count, by: bytesPerUnit).map {
                Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: UInt32.self)))
            }
        }
    }

    /// Maximal runs of consecutive indices, for compact messages and text.
    static func runs<C: Collection>(_ units: C) -> [ClosedRange<Int>] where C.Element == Int {
        var result: [ClosedRange<Int>] = []
        for unit in units {
            if let last = result.last, last.upperBound + 1 == unit {
                result[result.count - 1] = last.lowerBound...unit
            } else {
                result.append(unit...unit)
            }
        }
        return result
    }

    static func describe<C: Collection>(_ units: C) -> String where C.Element == Int {
        let parts = runs(units).map { $0.count == 1 ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)" }
        if parts.isEmpty { return "nothing" }
        if parts.count > 8 { return "[" + parts.prefix(8).joined(separator: ", ") + ", ... (\(parts.count) runs, \(units.count) ms)]" }
        return "[" + parts.joined(separator: ", ") + "] (\(units.count) ms)"
    }
}

/// How many generated scenarios reached each interaction at least once -
/// printed with the fuzz summary so a green run also shows what it covered.
@MainActor
enum LifecycleCoverage {
    private static var counts: [String: Int] = [:]

    static func add(_ reached: Set<String>) {
        for name in reached { counts[name, default: 0] += 1 }
    }

    static func summary() -> String {
        counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: ", ")
    }
}

private final class LifecycleDirtyFlag {
    var isDirty = true
}

// MARK: - The world and its oracle

@MainActor
final class LifecycleWorld {
    /// The documented bounds (docs/soniox-routing.md).
    static let outageBufferMs = 60_000
    static let resendCapMs = 15_000
    static let endGraceSeconds = 3.0
    static let endCloseSeconds = 1.5

    enum Phase: String {
        case idle, connecting, active, ended, authError
    }

    let clock = LifecycleVirtualClock()
    private(set) var sockets: [LifecycleFakeSocket] = []
    private(set) var monitors: [LifecycleFakePathMonitor] = []
    let capture = LifecycleFakeCapture()
    private(set) var controller: LiveSessionController!
    private var segmentsSubscription: AnyCancellable?
    private let segmentsDirty = LifecycleDirtyFlag()

    // Ground truth, maintained from the events alone.
    private(set) var phase: Phase = .idle
    private var paused = false
    private var endPending = false
    private var graceDeadline: Double?
    private var closeDeadline: Double?
    private var networkBanner = false
    private var userSession = 0
    private var pathUp = true
    private var nextUnit = 0
    /// Audio the next connection that gets established must receive first:
    /// the unfinalized tail of the connection that dropped...
    private var owedResend: [Int] = []
    /// ...then everything captured while no connection was established.
    private var owedOutage: [Int] = []
    private var expectedReceived: [Int: [Int]] = [:]
    /// Every final unit a live connection of the current session delivered,
    /// in delivery order - what the transcript's final text must show.
    private var appliedFinal: [ClosedRange<Int>] = []
    private var finAnswerApplied = false
    private var pendingViolation: LifecycleViolation?
    var recordsCoverage = false
    private(set) var coverage: Set<String> = []

    private func reached(_ name: String) {
        if recordsCoverage { coverage.insert(name) }
    }

    init() {
        let scheduler = LifecycleClockScheduler(clock: clock)
        let session = SonioxLiveSession(
            makeSocket: { [unowned self] in self.makeSocket() },
            scheduler: scheduler,
            makePathMonitor: { [unowned self] in self.makeMonitor() }
        )
        controller = LiveSessionController(
            apiKey: "placeholder-not-a-key",
            micPermission: FakeMicPermissionProvider(granted: true),
            audioCapture: capture,
            liveSession: session,
            translationAvailability: FakeMeToTargetAvailabilityChecker(),
            scheduler: scheduler
        )
        let flag = segmentsDirty
        segmentsSubscription = controller.$segments.sink { _ in flag.isDirty = true }
    }

    private func makeSocket() -> SonioxSocketConnecting {
        let socket = LifecycleFakeSocket(id: sockets.count + 1, userSession: userSession)
        sockets.append(socket)
        expectedReceived[socket.id] = []
        return socket
    }

    private func makeMonitor() -> NetworkPathMonitoring {
        let monitor = LifecycleFakePathMonitor()
        monitors.append(monitor)
        return monitor
    }

    private var establishedSocket: LifecycleFakeSocket? {
        sockets.first { $0.isEstablished }
    }

    private var handshakingSocket: LifecycleFakeSocket? {
        sockets.first { $0.isHandshaking }
    }

    private var isConnected: Bool {
        sockets.contains { $0.userSession == userSession && $0.isEstablished }
    }

    /// The session has not finished closing: auth still wins.
    private var isSessionLive: Bool {
        switch phase {
        case .connecting, .active: return true
        case .ended: return sockets.contains { $0.userSession == userSession && $0.isOpen }
        case .idle, .authError: return false
        }
    }

    private func violate(_ key: String, _ message: String) {
        if pendingViolation == nil {
            pendingViolation = LifecycleViolation(key: key, message: message)
        }
    }

    // MARK: Applying events

    /// Returns `false` when `event` is not possible right now (a disabled
    /// button, no socket in the right shape, ...) - it is then skipped,
    /// which is what makes any subsequence of a sequence replayable.
    func apply(_ event: LifecycleEvent) -> Bool {
        for socket in sockets { socket.clearChangeFlag() }
        switch event {
        case .tapPrimary:
            if phase == .ended, sockets.contains(where: \.isOpen) { reached("phienMoiInCloseWindow") }
            if phase == .active, !isConnected { reached(paused ? "resumeWhileDisconnected" : "pauseWhileDisconnected") }
            if phase == .active, paused, isConnected { reached("resumeWhileConnected") }
            return tapPrimary()
        case .confirmEnd:
            return confirmEnd()
        case .audio(let ms):
            return deliverAudio(ms: ms)
        case .connectSucceeds:
            guard pathUp, let socket = handshakingSocket else { return false }
            establish(socket)
            return true
        case .connectFails:
            guard let socket = handshakingSocket else { return false }
            fail(socket)
            return true
        case .drop:
            guard let socket = establishedSocket else { return false }
            drop(socket)
            return true
        case let .response(finalPermille, tailPermille, speaker, english, endMarker):
            guard let socket = sockets.first(where: { $0.isEstablished && !$0.answeredFinalize }) else { return false }
            respond(on: socket, finalPermille: finalPermille, tailPermille: tailPermille, speaker: speaker, english: english, endMarker: endMarker)
            return true
        case .finAnswer:
            guard let socket = sockets.first(where: { $0.isEstablished && $0.finalizeRequested && !$0.answeredFinalize }) else { return false }
            answerFinalize(on: socket)
            return true
        case .authRejected(let pick):
            let open = sockets.filter(\.isOpen)
            guard !open.isEmpty else { return false }
            let socket = open[pick % open.count]
            if socket.userSession == userSession, isSessionLive {
                reached("authWhile_\(phase.rawValue)\(endPending ? "_endPending" : "")")
                enterAuthError()
            }
            socket.onEvent?(.authRejected)
            if !socket.dead, !socket.closedByApp {
                // The server closes the connection after an auth error.
                socket.dead = true
                socket.onEvent?(.closed(LifecycleNetworkError()))
            }
            return true
        case .pathAvailable:
            if phase == .active, !isConnected, handshakingSocket == nil { reached("pathPreemptsBackoff") }
            pathUp = true
            for monitor in monitors where monitor.isLive {
                monitor.onPathAvailable?()
            }
            return true
        case .pathLost(let dropsConnections):
            guard pathUp else { return false }
            pathUp = false
            if dropsConnections {
                if let socket = establishedSocket { drop(socket) }
                if let socket = handshakingSocket { fail(socket) }
            }
            return true
        case .advance(let ms):
            advanceClock(to: clock.now + Double(ms) / 1000)
            return true
        case .fireNextTimer:
            guard let due = clock.nextDue else { return false }
            advanceClock(to: max(due, clock.now))
            return true
        case let .staleSocketEvent(kind, pick):
            let closed = sockets.filter(\.closedByApp)
            guard !closed.isEmpty else { return false }
            reached("staleSocketEvent")
            deliverStale(kind: kind, to: closed[pick % closed.count])
            return true
        case .stalePathEvent:
            guard let monitor = monitors.last(where: { $0.started && $0.cancelled }) else { return false }
            monitor.onPathAvailable?()
            return true
        }
    }

    private func tapPrimary() -> Bool {
        // The button is disabled while connecting, in authError, and
        // during the end grace wait (HANDOFF section 5, round 5 finding 4).
        guard !endPending else { return false }
        switch phase {
        case .connecting, .authError:
            return false
        case .idle, .ended:
            let isNewSession = phase == .ended
            userSession += 1
            phase = .connecting
            paused = false
            graceDeadline = nil
            closeDeadline = nil
            owedResend = []
            owedOutage = []
            appliedFinal = []
            finAnswerApplied = false
            segmentsDirty.isDirty = true
            controller.primaryButtonTapped()
            if isNewSession, !controller.segments.isEmpty {
                violate("(g) new session", "Phiên mới kept \(controller.segments.count) segment(s) from the previous session")
            }
        case .active:
            paused.toggle()
            controller.primaryButtonTapped()
        }
        return true
    }

    private func confirmEnd() -> Bool {
        guard phase == .connecting || phase == .active, !endPending else { return false }
        let established = sockets.first { $0.userSession == userSession && $0.isEstablished }
        if phase == .active, established == nil {
            reached(paused ? "endWhilePausedAndDisconnected" : "endWhileReconnecting")
            // Ending mid-reconnect (paused or not): the mic stops now, the
            // session ends once the grace wait elapses.
            endPending = true
            graceDeadline = clock.now + Self.endGraceSeconds
            controller.endSession()
            return true
        }
        enterEnded(at: clock.now)
        controller.endSession()
        if let established, !established.finalizeRequested {
            violate("(f) end", "Kết thúc did not send finalize to the established connection #\(established.id)")
        }
        return true
    }

    private func enterEnded(at time: Double) {
        phase = .ended
        endPending = false
        graceDeadline = nil
        closeDeadline = time + Self.endCloseSeconds
        // Documented: once ended, audio still waiting for a connection is dropped.
        owedResend = []
        owedOutage = []
    }

    private func enterAuthError() {
        phase = .authError
        endPending = false
        paused = false
        graceDeadline = nil
        closeDeadline = nil
        owedResend = []
        owedOutage = []
    }

    private func deliverAudio(ms: Int) -> Bool {
        guard capture.isRunning else { return false }
        let units = nextUnit..<(nextUnit + ms)
        nextUnit += ms
        if let socket = sockets.first(where: { $0.userSession == userSession && $0.isEstablished }), phase == .active {
            expectedReceived[socket.id, default: []] += Array(units)
        } else if phase == .connecting || phase == .active {
            owedOutage += Array(units)
            if owedOutage.count > Self.outageBufferMs {
                reached("outageOver60s")
                owedOutage.removeFirst(owedOutage.count - Self.outageBufferMs)
            }
        }
        capture.onAudioBuffer?(LifecycleAudio.encode(units))
        return true
    }

    private func establish(_ socket: LifecycleFakeSocket) {
        socket.configAccepted = true
        let belongs = socket.userSession == userSession
        let expectsDelivery = belongs && (phase == .connecting || phase == .active)
        var expected: [Int] = []
        if expectsDelivery {
            if phase == .active { reached(paused ? "reconnectedWhilePaused" : endPending ? "reconnectedDuringEndGrace" : "reconnected") }
            if !owedResend.isEmpty { reached("resendNonEmpty") }
            expected = owedResend + owedOutage
            expectedReceived[socket.id] = expected
            owedResend = []
            owedOutage = []
        }
        if belongs, phase == .connecting {
            phase = .active
            networkBanner = false
        }
        socket.onEvent?(.configSent)
        if expectsDelivery, socket.received != expected {
            violate("(c) audio delivery", "connection #\(socket.id) was established and received \(LifecycleAudio.describe(socket.received)) but the documented bounds require exactly \(LifecycleAudio.describe(expected)) (resend of the dropped connection's unfinalized last \(Self.resendCapMs / 1000) s, then the outage buffer)")
        }
    }

    private func fail(_ socket: LifecycleFakeSocket) {
        socket.dead = true
        if socket.userSession == userSession, phase == .connecting {
            phase = .idle
            networkBanner = true
            owedResend = []
            owedOutage = []
        }
        socket.onEvent?(.closed(LifecycleNetworkError()))
    }

    private func drop(_ socket: LifecycleFakeSocket) {
        socket.dead = true
        if socket.userSession == userSession, phase == .active {
            let end = socket.received.count
            let from = max(socket.serverFinalizedMs, end - Self.resendCapMs)
            if end - Self.resendCapMs > socket.serverFinalizedMs { reached("resendCappedAt15s") }
            if socket.serverFinalizedMs > 0, from < end { reached("resendAfterPartialFinalize") }
            if paused { reached("dropWhilePaused") }
            owedResend = from < end ? Array(socket.received[from..<end]) : []
        }
        socket.onEvent?(.closed(LifecycleNetworkError()))
    }

    private func finalTokens(_ units: ArraySlice<Int>, speaker: Int, english: Bool) -> [SonioxToken] {
        LifecycleAudio.runs(units).map {
            SonioxToken(text: " u\($0.lowerBound)_\($0.upperBound)", isFinal: true, startMs: nil, endMs: nil,
                        speaker: speaker == 0 ? nil : "\(speaker)", language: english ? "en" : "vi", translationStatus: .original)
        }
    }

    private func respond(on socket: LifecycleFakeSocket, finalPermille: Int, tailPermille: Int, speaker: Int, english: Bool, endMarker: Bool) {
        let count = socket.received.count
        let oldFinal = socket.serverFinalizedMs
        let newFinal = oldFinal + (count - oldFinal) * finalPermille / 1000
        let tailEnd = newFinal + (count - newFinal) * tailPermille / 1000
        var tokens = finalTokens(socket.received[oldFinal..<newFinal], speaker: speaker, english: english)
        if endMarker {
            tokens.append(SonioxToken(text: "<end>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .original))
        }
        tokens += LifecycleAudio.runs(socket.received[newFinal..<tailEnd]).map {
            SonioxToken(text: " n\($0.lowerBound)_\($0.upperBound)", isFinal: false, startMs: nil, endMs: nil,
                        speaker: speaker == 0 ? nil : "\(speaker)", language: nil, translationStatus: .original)
        }
        recordApplied(socket.received[oldFinal..<newFinal], from: socket)
        socket.serverFinalizedMs = newFinal
        socket.onEvent?(.response(SonioxSocketResponse(tokens: tokens, finalAudioProcMs: newFinal)))
    }

    private func answerFinalize(on socket: LifecycleFakeSocket) {
        let count = socket.received.count
        let oldFinal = socket.serverFinalizedMs
        var tokens = finalTokens(socket.received[oldFinal..<count], speaker: 1, english: false)
        tokens.append(SonioxToken(text: "<fin>", isFinal: true, startMs: nil, endMs: nil, speaker: nil, language: nil, translationStatus: .original))
        if recordApplied(socket.received[oldFinal..<count], from: socket) {
            reached("finAnswerApplied")
            finAnswerApplied = true
        }
        socket.serverFinalizedMs = count
        socket.answeredFinalize = true
        socket.onEvent?(.response(SonioxSocketResponse(tokens: tokens, finalAudioProcMs: count)))
    }

    /// A response from an open connection of the current session is real
    /// output the transcript must keep - including in the window after
    /// Kết thúc, before the connection closes.
    @discardableResult
    private func recordApplied(_ units: ArraySlice<Int>, from socket: LifecycleFakeSocket) -> Bool {
        guard socket.userSession == userSession, phase == .active || phase == .ended else { return false }
        segmentsDirty.isDirty = true
        for run in LifecycleAudio.runs(units) {
            if let last = appliedFinal.last, run.lowerBound <= last.upperBound {
                violate("(d) transcript", "audio \(run) was finalized twice (already finalized up to \(last.upperBound)) - it was resent after a server had finalized it")
            }
            if let last = appliedFinal.last, last.upperBound + 1 == run.lowerBound {
                appliedFinal[appliedFinal.count - 1] = last.lowerBound...run.upperBound
            } else {
                appliedFinal.append(run)
            }
        }
        return true
    }

    private func deliverStale(kind: Int, to socket: LifecycleFakeSocket) {
        switch kind % 4 {
        case 0:
            socket.onEvent?(.closed(LifecycleNetworkError()))
        case 1:
            socket.onEvent?(.configSent)
        case 2:
            let units = socket.received.isEmpty ? [900_000_000 + socket.id] : Array(socket.received)
            let tokens = finalTokens(units[...], speaker: 2, english: true)
            socket.onEvent?(.response(SonioxSocketResponse(tokens: tokens, finalAudioProcMs: units.count)))
        default:
            // An auth rejection that was already on its way when the app
            // closed the socket still wins while its session is live.
            if socket.userSession == userSession, isSessionLive { enterAuthError() }
            socket.onEvent?(.authRejected)
        }
    }

    private func advanceClock(to target: Double) {
        let establishedBefore = sockets.first { $0.userSession == userSession && $0.isEstablished }
        clock.advance(to: target)
        if endPending, let deadline = graceDeadline, clock.now >= deadline {
            reached(establishedBefore == nil ? "graceExpiredDisconnected" : "graceExpiredConnected")
            enterEnded(at: deadline)
            if let establishedBefore, !establishedBefore.finalizeRequested {
                violate("(f) end", "the end grace wait elapsed with connection #\(establishedBefore.id) established, but it never received finalize")
            }
        }
    }

    // MARK: Invariants

    private var expectedState: SessionState {
        switch phase {
        case .idle: return .idle
        case .connecting: return .connecting
        case .ended: return .ended
        case .authError: return .authError
        case .active: return paused ? .paused : (isConnected ? .listening : .reconnecting)
        }
    }

    private var expectedMicOn: Bool {
        switch phase {
        case .connecting: return true
        case .active: return !paused && !endPending
        case .idle, .ended, .authError: return false
        }
    }

    /// HANDOFF section 5's dock vocabulary, from ground truth.
    private var expectedDockText: String {
        let state = expectedState
        if expectedMicOn { return state == .reconnecting ? "Mic giữ, chờ mạng" : "Đang nghe" }
        switch state {
        case .paused: return "Đã tạm dừng"
        case .connecting, .requestingMic: return "Đang mở mic…"
        default: return "Mic tắt"
        }
    }

    func check() -> LifecycleViolation? {
        if let pendingViolation { return pendingViolation }

        // (a) one open connection at most, none once stopped.
        let open = sockets.filter(\.isOpen)
        if open.count > 1 {
            return LifecycleViolation(key: "(a) connections", message: "\(open.count) connections open at once: \(open.map { "#\($0.id)" }.joined(separator: ", "))")
        }
        if let stray = open.first(where: { $0.userSession != userSession }) {
            return LifecycleViolation(key: "(g) new session", message: "connection #\(stray.id) from a previous session is still open")
        }
        if let socket = open.first {
            switch phase {
            case .idle:
                return LifecycleViolation(key: "(a) connections", message: "connection #\(socket.id) is still open on an idle screen")
            case .authError:
                return LifecycleViolation(key: "(e) auth", message: "connection #\(socket.id) is still open after the key was rejected")
            case .ended where clock.now >= (closeDeadline ?? 0):
                return LifecycleViolation(key: "(f) end", message: "connection #\(socket.id) is still open \(Self.endCloseSeconds) s after the session ended")
            default:
                break
            }
        }
        let liveMonitors = monitors.filter(\.isLive)
        if liveMonitors.count > 1 {
            return LifecycleViolation(key: "(g) new session", message: "\(liveMonitors.count) path monitors running at once")
        }
        if !liveMonitors.isEmpty, phase != .connecting, phase != .active {
            return LifecycleViolation(key: "(g) new session", message: "a path monitor is still running while \(phase.rawValue)")
        }

        // (c) every socket received exactly what the oracle expects.
        for socket in sockets {
            if let misuse = socket.misuse {
                return LifecycleViolation(key: "(c) audio delivery", message: misuse)
            }
            let expected = expectedReceived[socket.id] ?? []
            if socket.received.count != expected.count || (socket.receivedChanged && socket.received != expected) {
                return LifecycleViolation(key: "(c) audio delivery", message: "connection #\(socket.id) received \(LifecycleAudio.describe(socket.received)); expected exactly \(LifecycleAudio.describe(expected))")
            }
        }

        // (b) what the screen says is true.
        let state = expectedState
        if controller.state != state {
            return LifecycleViolation(key: "(b) displayed state .\(controller.state) instead of .\(state)", message: "screen shows .\(controller.state) but the truth is .\(state) (phase \(phase.rawValue), paused \(paused), connected \(isConnected), end pending \(endPending))")
        }
        if capture.isRunning != expectedMicOn || controller.isMicCapturing != capture.isRunning {
            return LifecycleViolation(key: "(b) displayed state", message: "mic running \(capture.isRunning), shown as capturing \(controller.isMicCapturing), but it should be \(expectedMicOn ? "on" : "off")")
        }
        if controller.micDockText != expectedDockText {
            return LifecycleViolation(key: "(b) displayed state", message: "dock says \"\(controller.micDockText)\", truth is \"\(expectedDockText)\"")
        }
        if controller.isEndPending != endPending {
            return LifecycleViolation(key: "(b) displayed state", message: "isEndPending \(controller.isEndPending), truth \(endPending)")
        }
        let canEnd = (phase == .connecting || phase == .active) && !endPending
        if controller.canEnd != canEnd {
            return LifecycleViolation(key: "(b) displayed state", message: "canEnd \(controller.canEnd), truth \(canEnd)")
        }
        if controller.showsNetworkErrorBanner != networkBanner {
            return LifecycleViolation(key: "(b) displayed state", message: "\"Lỗi mạng, thử lại sau\" shown \(controller.showsNetworkErrorBanner), truth \(networkBanner)")
        }
        if controller.showsTranslationUnavailableBanner {
            return LifecycleViolation(key: "(b) displayed state", message: "translation-unavailable banner shown with no availability result")
        }

        // (d) and (f): the transcript keeps every finalized unit once.
        if segmentsDirty.isDirty {
            segmentsDirty.isDirty = false
            if let violation = checkTranscript() { return violation }
        }
        return nil
    }

    private func checkTranscript() -> LifecycleViolation? {
        let key = phase == .ended ? "(f) end" : "(d) transcript"
        let segments = controller.segments
        if Set(segments.map(\.id)).count != segments.count {
            return LifecycleViolation(key: "(d) transcript", message: "duplicate segment ids \(segments.map(\.id))")
        }
        var shown: [ClosedRange<Int>] = []
        for segment in segments {
            for word in segment.source.split(separator: " ") where word.first == "u" {
                let bounds = word.dropFirst().split(separator: "_").compactMap { Int($0) }
                guard bounds.count == 2 else { continue }
                if let last = shown.last, last.upperBound + 1 == bounds[0] {
                    shown[shown.count - 1] = last.lowerBound...bounds[1]
                } else {
                    shown.append(bounds[0]...bounds[1])
                }
            }
        }
        if shown != appliedFinal {
            return LifecycleViolation(key: key, message: "transcript shows final audio \(describeRuns(shown)) but the server finalized \(describeRuns(appliedFinal))")
        }
        if finAnswerApplied, let draft = segments.first(where: { !$0.isFinal }) {
            return LifecycleViolation(key: "(f) end", message: "segment \(draft.id) is still a draft after the <fin> answer to Kết thúc")
        }
        return nil
    }

    private func describeRuns(_ runs: [ClosedRange<Int>]) -> String {
        if runs.isEmpty { return "nothing" }
        let parts = runs.map { "\($0.lowerBound)-\($0.upperBound)" }
        return parts.count > 8 ? "[" + parts.prefix(8).joined(separator: ", ") + ", ... (\(parts.count) runs)]" : "[" + parts.joined(separator: ", ") + "]"
    }

    func snapshot() -> String {
        let open = sockets.filter(\.isOpen).map { "#\($0.id)\($0.configAccepted ? "" : "?")" }
        return "t=\(String(format: "%.1f", clock.now))s state=.\(controller.state) mic=\(capture.isRunning ? "on" : "off") endPending=\(controller.isEndPending) open=[\(open.joined(separator: ","))] truth=\(phase.rawValue)\(paused ? "+paused" : "")\(isConnected ? "+connected" : "")"
    }

    // MARK: Generation

    func propose(_ rng: inout LifecycleRandom) -> LifecycleEvent {
        var options: [(weight: Int, make: (inout LifecycleRandom) -> LifecycleEvent)] = []
        func add(_ weight: Int, _ make: @escaping (inout LifecycleRandom) -> LifecycleEvent) {
            if weight > 0 { options.append((weight, make)) }
        }
        let established = establishedSocket != nil
        let handshaking = handshakingSocket != nil
        switch phase {
        case .idle:
            add(8) { _ in .tapPrimary }
        case .ended:
            add(3) { _ in .tapPrimary }
        case .connecting:
            add(pathUp ? 6 : 0) { _ in .connectSucceeds }
            add(2) { _ in .connectFails }
            add(1) { _ in .confirmEnd }
        case .active:
            add(endPending ? 0 : 3) { _ in .tapPrimary }
            add(endPending ? 0 : 1) { _ in .confirmEnd }
            add(established ? 3 : 0) { _ in .drop }
            add(handshaking && pathUp ? 6 : 0) { _ in .connectSucceeds }
            add(handshaking ? 2 : 0) { _ in .connectFails }
            add(pathUp ? 1 : 0) { rng in .pathLost(dropsConnections: rng.chance(70)) }
            add(pathUp ? 1 : 4) { _ in .pathAvailable }
            add(clock.nextDue != nil ? 4 : 0) { _ in .fireNextTimer }
        case .authError:
            add(1) { _ in .advance(ms: 5000) }
        }
        // Long captures while no connection is established are what reach
        // the 60 s outage bound and the 15 s resend bound.
        let disconnected = phase == .connecting || (phase == .active && !isConnected)
        add(capture.isRunning ? 8 : 0) { rng in
            let bucket = rng.int(0...99)
            if disconnected, bucket < 20 { return .audio(ms: rng.int(15_000...30_000)) }
            if bucket < 50 { return .audio(ms: rng.int(20...400)) }
            if bucket < 80 { return .audio(ms: rng.int(500...2500)) }
            return .audio(ms: rng.int(3000...10_000))
        }
        add(established ? 6 : 0) { rng in
            let anyPermille = rng.int(0...1000)
            let finalPermille = rng.pick([0, 100, 250, 500, 750, 1000, anyPermille])
            let tailPermille = rng.pick([0, 500, 1000])
            let speaker = rng.int(0...2)
            let english = rng.chance(40)
            let endMarker = rng.chance(35)
            return .response(finalPermille: finalPermille, tailPermille: tailPermille, speaker: speaker, english: english, endMarker: endMarker)
        }
        add(sockets.contains { $0.isEstablished && $0.finalizeRequested && !$0.answeredFinalize } ? 6 : 0) { _ in .finAnswer }
        add(sockets.contains(where: \.isOpen) ? 1 : 0) { rng in .authRejected(pick: rng.int(0...3)) }
        add(sockets.contains(where: \.closedByApp) ? 2 : 0) { rng in .staleSocketEvent(kind: rng.int(0...3), pick: rng.int(0...7)) }
        add(monitors.contains { $0.cancelled } ? 1 : 0) { _ in .stalePathEvent }
        add(2) { rng in .advance(ms: rng.pick([50, 200, 500, 1000, 1500, 2000, 3000, 5000, 10_000, 30_000])) }
        add(clock.nextDue != nil ? 1 : 0) { _ in .fireNextTimer }

        let total = options.reduce(0) { $0 + $1.weight }
        var roll = rng.int(0...(total - 1))
        for option in options {
            if roll < option.weight { return option.make(&rng) }
            roll -= option.weight
        }
        return .advance(ms: 1000)
    }
}
