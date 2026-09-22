import SwiftUI

/// HANDOFF.md section 2.1. The real-key path validates against the actual
/// Soniox service (`SonioxAPIClient`) and stores the key in Keychain only -
/// AGENTS.md's rule that a key never appears anywhere else in the app or
/// the repo. The prototype's `sx_...` key-pattern check and its
/// "Dán khóa demo" affordance are `[mô phỏng]` per HANDOFF.md; a pasted
/// demo key would predictably fail real validation, so this file does not
/// reuse either. Whether to keep, drop, or replace that affordance for a
/// live build is an open question for the project owner, not a decision
/// made here.
struct SetupView: View {
    let onKeyValidated: (String) -> Void
    let onStartDemo: () -> Void

    private enum ValidationState: Equatable {
        case notChecked
        case checking
        case valid(warning: String?)
        case invalidKey
        case networkError
    }

    @State private var apiKey: String = ""
    @State private var isKeyVisible = false
    @State private var validationState: ValidationState = .notChecked

    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var demoButtonSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var footerSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var fieldSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var statusSize: CGFloat = 13

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            VStack(spacing: 20) {
                Spacer()

                Image(systemName: "waveform")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(Tokens.accent)

                Text("Kết nối Soniox")
                    .font(.system(size: titleSize, weight: .bold))
                    .foregroundStyle(Tokens.text)

                Text("Sermiva dùng Soniox để nhận dạng và dịch theo thời gian thực. Dán khóa API của bạn để bắt đầu.")
                    .font(.system(size: bodySize))
                    .foregroundStyle(Tokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                keyField

                if let statusText {
                    Text(statusText)
                        .font(.system(size: statusSize, weight: .medium))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 20)
                }

                Button(action: checkAndContinue) {
                    if validationState == .checking {
                        ProgressView().tint(Tokens.onAccent)
                            .frame(maxWidth: .infinity, minHeight: 52)
                    } else {
                        Text("Kiểm tra và tiếp tục")
                            .font(.system(size: buttonSize, weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                }
                .background(canCheck ? Tokens.accent : Tokens.accent.opacity(0.5))
                .foregroundStyle(Tokens.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(!canCheck)
                .padding(.horizontal, 20)
                .accessibilityIdentifier("checkAndContinueButton")

                Button(action: onStartDemo) {
                    Text("Dùng thử bản demo (không nối Soniox)")
                        .font(.system(size: demoButtonSize, weight: .medium))
                }
                .foregroundStyle(Tokens.accent)
                .frame(minHeight: 44)
                .accessibilityIdentifier("demoButton")

                Text("Khóa chỉ lưu trên máy này.")
                    .font(.system(size: footerSize))
                    .foregroundStyle(Tokens.text3)

                Spacer()
            }
            .padding(.horizontal, 20)
        }
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCheck: Bool {
        !trimmedKey.isEmpty && validationState != .checking
    }

    private var statusText: String? {
        switch validationState {
        case .notChecked: return nil
        case .checking: return "Đang kiểm tra…"
        case .valid(let warning): return warning ?? "Khóa hợp lệ"
        case .invalidKey: return "Khóa không hợp lệ"
        case .networkError: return "Lỗi mạng. Thử lại."
        }
    }

    private var statusColor: Color {
        switch validationState {
        case .valid: return Tokens.ok
        case .invalidKey, .networkError: return Tokens.danger
        case .notChecked, .checking: return Tokens.text3
        }
    }

    private func checkAndContinue() {
        let key = trimmedKey
        validationState = .checking
        Task {
            let outcome = await SonioxAPIClient.validateKey(
                key,
                meLanguage: LiveLanguageConfig.default.me,
                targetLanguage: LiveLanguageConfig.default.target
            )
            await MainActor.run {
                switch outcome {
                case .valid(let warning):
                    validationState = .valid(warning: warning)
                    SonioxKeychainStore.saveKey(key)
                    onKeyValidated(key)
                case .invalidKey:
                    validationState = .invalidKey
                case .networkError, .unusableConfiguration:
                    // The key itself was accepted for `.unusableConfiguration` -
                    // HANDOFF's status vocabulary has no case for "valid key,
                    // unusable model/languages", so this reuses the existing
                    // "Lỗi mạng" copy rather than inventing new text. See the
                    // hand-off report's owner questions.
                    validationState = .networkError
                }
            }
        }
    }

    private var keyField: some View {
        HStack {
            Group {
                if isKeyVisible {
                    TextField("sx_...", text: $apiKey)
                } else {
                    SecureField("sx_...", text: $apiKey)
                }
            }
            .font(.system(size: fieldSize, design: .monospaced))
            .foregroundStyle(Tokens.text)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)

            Button(action: { isKeyVisible.toggle() }) {
                Image(systemName: isKeyVisible ? "eye.slash" : "eye")
                    .foregroundStyle(Tokens.text3)
            }
            .frame(width: 44, height: 44)
            .accessibilityLabel(isKeyVisible ? "Ẩn khóa" : "Hiện khóa")
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 20)
    }
}
