import Foundation
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
