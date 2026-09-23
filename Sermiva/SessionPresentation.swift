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
        // Checked before the generic `isMicCapturing` rule below: per
        // HANDOFF section 5, "Mic giữ, chờ mạng" describes this state
        // specifically - the mic keeps capturing while reconnecting (it is
        // never stopped for a network-only event), so the generic
        // "Đang nghe" rule would otherwise always win here and make this
        // string unreachable in the one situation it exists for.
        //
        // Review round 5, lead ruling (finding 5): also requires
        // `isMicCapturing`. Confirming Kết thúc while `.reconnecting` now
        // stops the mic immediately, before the grace wait, while `state`
        // itself stays `.reconnecting` throughout - without this,
        // "Mic giữ, chờ mạng" would keep claiming the mic is held even
        // though it has genuinely stopped. The switch below already listed
        // `.reconnecting` among the "Mic tắt" cases; this is what makes
        // that existing, previously-unreachable line reachable exactly
        // when it becomes true - no new copy.
        if state == .reconnecting, isMicCapturing {
            return "Mic giữ, chờ mạng"
        }
        if isMicCapturing {
            return "Đang nghe"
        }
        switch state {
        case .paused: return "Đã tạm dừng"
        case .requestingMic, .connecting: return "Đang mở mic…"
        case .micDenied: return "Chưa có quyền mic"
        case .idle, .ended, .authError, .listening, .reconnecting: return "Mic tắt"
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

    /// HANDOFF.md section 4: `{me} ↔ {guest|Tự nhận diện}` + ` · {target}`
    /// when `target ≠ guest`. `guestHint == nil` means "auto" (Tự nhận
    /// diện), which is never equal to any real target code, so the
    /// ` · {target}` suffix always shows in that case.
    static func languageHeaderText(config: LiveLanguageConfig) -> String {
        let guestText = config.guestHint.map(LanguageNames.display) ?? "Tự nhận diện"
        var text = "\(LanguageNames.display(for: config.me)) ↔ \(guestText)"
        if config.guestHint != config.target {
            text += " · \(LanguageNames.display(for: config.target))"
        }
        return text
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
