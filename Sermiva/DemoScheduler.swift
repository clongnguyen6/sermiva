import Foundation

/// Wraps timed playback so the session state machine can be driven by a
/// manual, instant fake in tests instead of a real clock.
protocol DemoScheduler {
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void)
}

struct DispatchScheduler: DemoScheduler {
    func schedule(after seconds: TimeInterval, _ action: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: action)
    }
}
