import Foundation

/// Wraps a microphone-permission decision so the session state machine can
/// be driven by a fake in tests, or by the demo's own inert stand-in,
/// without a real system alert. Both the method and its completion are
/// pinned to the main actor so conforming types (and the controller calling
/// them) never need a `Task` hop of their own.
protocol MicPermissionProviding {
    @MainActor func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void)
}

/// The production permission provider for demo mode. Per the project
/// owner's decision, demo never asks for the real OS microphone permission
/// - it has nothing to use it for, and requesting it would light the
/// privacy indicator and make demo indistinguishable from a live session.
/// Always resolves granted, so the section-5 state machine still passes
/// through `requestingMic -> connecting -> listening` exactly as designed,
/// just without a real system prompt behind it. The real prompt belongs to
/// Outcome 2. See docs/demo-mic-status.md.
struct AutoGrantedMicPermission: MicPermissionProviding {
    @MainActor func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
}
