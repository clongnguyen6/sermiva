import Foundation
import Network

/// Detects the moment the device's own network path becomes available again
/// - review round 4, finding 4a (owner decision): the live session's second
/// mock conversation showed roughly 30 s from the network genuinely coming
/// back to the app actually reconnecting, all of it spent waiting out
/// backoff it no longer needed to. `NWPathMonitor` (wrapped by
/// `RealNetworkPathMonitor` below) is a system framework already linked
/// into every iOS app - not a new dependency. Only "became available" is
/// reported: `SonioxLiveSession` already learns about a drop from the
/// socket itself, so this seam has nothing useful to add for that
/// direction.
@MainActor
protocol NetworkPathMonitoring: AnyObject {
    var onPathAvailable: (() -> Void)? { get set }
    func start()
    /// `nonisolated` so `SonioxLiveSession.deinit` (necessarily nonisolated
    /// for a `@MainActor` class) can guarantee this is cancelled even if
    /// nothing else ever calls it - matches `SonioxSocketConnecting.close()`'s
    /// own reasoning.
    nonisolated func cancel()
}

/// `NWPathMonitor`'s own handler runs on the queue passed to `start(queue:)`,
/// never guaranteed to be the main actor, so it is hopped back with
/// `Task { @MainActor in ... }` before ever touching `onPathAvailable` -
/// exactly `SonioxStreamSocket`'s own established pattern for the same
/// reason.
@MainActor
final class RealNetworkPathMonitor: NetworkPathMonitoring {
    var onPathAvailable: (() -> Void)?

    // `NWPathMonitor` is itself `Sendable` (and `cancel()` is documented
    // thread-safe), so a plain `let` is already safe to read from
    // `cancel()`'s own nonisolated context (see the protocol's doc comment)
    // with no `nonisolated(unsafe)` escape hatch needed.
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.clongnguyen6.sermiva.networkpathmonitor")

    func start() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in
                self?.onPathAvailable?()
            }
        }
        monitor.start(queue: queue)
    }

    nonisolated func cancel() {
        monitor.cancel()
    }
}
