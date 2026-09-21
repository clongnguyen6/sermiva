import AVFAudio

/// Wraps the system microphone-permission prompt so the session state
/// machine can be driven by a fake in tests instead of a real system alert.
///
/// Both the method and its completion are pinned to the main actor: the
/// real implementation hops there itself (AVAudioApplication's own callback
/// is not main-actor-isolated), so `DemoSessionController` can call this
/// synchronously without a `Task` hop of its own - the fake completes
/// immediately, keeping state-machine tests synchronous.
protocol MicPermissionProviding {
    @MainActor func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void)
}

struct SystemMicPermissionProvider: MicPermissionProviding {
    @MainActor func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in completion(granted) }
        }
    }
}
