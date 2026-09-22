import Foundation

/// The section-5 state machine's dock and activity presentation rules,
/// factored out so `DemoSessionController` and `LiveSessionController`
/// share exactly one copy of each - not two that can drift. Everything here
/// is pure and controller-agnostic; see `DemoSessionController` for why
/// `isDemo` still wins outright over real capture state.
enum SessionPresentation {
    enum MicDotColorRole: Equatable {
        case neutral, warn, live
    }

    static func micDockText(isMicCapturing: Bool, state: SessionState, isDemo: Bool) -> String {
        if isDemo {
            return "Mic tắt"
        }
        if isMicCapturing {
            return "Đang nghe"
        }
        switch state {
        case .paused: return "Đã tạm dừng"
        case .requestingMic, .connecting: return "Đang mở mic…"
        case .reconnecting: return "Mic giữ, chờ mạng"
        case .micDenied: return "Chưa có quyền mic"
        case .idle, .ended, .authError, .listening: return "Mic tắt"
        }
    }

    static func micDotColorRole(isMicCapturing: Bool, state: SessionState, isDemo: Bool) -> MicDotColorRole {
        guard !isDemo else { return .neutral }
        if isMicCapturing { return .live }
        if state == .connecting || state == .requestingMic { return .warn }
        return .neutral
    }

    static func micIconName(isMicCapturing: Bool, isDemo: Bool) -> String {
        (!isDemo && isMicCapturing) ? "mic.fill" : "mic.slash"
    }

    static func isActivityRunning(for state: SessionState) -> Bool {
        state == .listening
    }

    static func canEnd(for state: SessionState) -> Bool {
        switch state {
        case .requestingMic, .connecting, .listening, .paused, .reconnecting:
            return true
        case .idle, .micDenied, .authError, .ended:
            return false
        }
    }
}
