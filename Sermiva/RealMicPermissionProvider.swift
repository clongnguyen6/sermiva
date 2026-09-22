import AVFAudio

/// The production permission provider for a live session: asks the real
/// system microphone-permission dialog, exactly once per HANDOFF.md section
/// 5 ("xin quyền micro đúng lúc nhấn Bắt đầu lần đầu"). A later tap while
/// still denied re-checks the OS's current answer rather than remembering
/// the old denial, the same contract `DemoSessionController`'s tests
/// already cover for `AutoGrantedMicPermission`.
struct RealMicPermissionProvider: MicPermissionProviding {
    @MainActor func requestPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in
                completion(granted)
            }
        }
    }
}
