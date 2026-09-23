import SwiftUI
import Translation

/// HANDOFF.md section 2.1. The real-key path validates against the actual
/// Soniox service (`SonioxAPIClient`) and stores the key in Keychain only -
/// AGENTS.md's rule that a key never appears anywhere else in the app or
/// the repo. The prototype's `sx_...` key-pattern check and its
/// "Dán khóa demo" affordance are `[mô phỏng]` per HANDOFF.md, and the
/// project owner has approved dropping both: a pasted demo key would
/// predictably fail real validation, so neither has a place here.
/// "Dùng thử bản demo (không nối Soniox)" is unaffected and stays.
struct SetupView: View {
    let onKeyValidated: (String) -> Void
    let onStartDemo: () -> Void

    private enum ValidationState: Equatable {
        case notChecked
        case checking
        case valid(warning: String?)
        case invalidKey
        case unusableConfiguration
        case networkError
    }

    @State private var apiKey: String = ""
    @State private var isKeyVisible = false
    @State private var validationState: ValidationState = .notChecked
    /// The outcome's Setup download step: `nil` until a validated key's
    /// `me -> target` availability turns out `.supported` (needs a
    /// download), at which point this is set once to trigger
    /// `.translationTask` below - the system's own permission/progress UI,
    /// which this view cannot restyle. Never reused as a stored session -
    /// `prepareTranslation()` inside that closure is the only call made
    /// through it.
    @State private var translationDownloadConfiguration: TranslationSession.Configuration?
    /// The key already saved to Keychain, waiting for the download check
    /// above to settle (successfully, unsupported, declined, or errored)
    /// before actually continuing to the conversation.
    @State private var keyPendingTranslationCheck: String?

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
                .disabled(isProcessing)
                .opacity(isProcessing ? 0.5 : 1)
                .accessibilityIdentifier("demoButton")

                Text("Khóa chỉ lưu trên máy này.")
                    .font(.system(size: footerSize))
                    .foregroundStyle(Tokens.text3)

                Spacer()
            }
            .padding(.horizontal, 20)
        }
        .translationTask(translationDownloadConfiguration) { session in
            defer { finishTranslationCheck() }
            try? await session.prepareTranslation()
        }
    }

    private var trimmedKey: String {
        apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True from the moment "Kiểm tra và tiếp tục" is tapped until either a
    /// terminal failure (`invalidKey`/`unusableConfiguration`/`networkError`)
    /// or `onKeyValidated` actually fires - which includes the async
    /// download-check window between a `.valid` key and the actual handoff.
    /// Review round 2, finding 4: without covering that whole window, a
    /// second tap re-ran the download check (setting its `@State`
    /// configuration a second time) and "Dùng thử bản demo" stayed tappable,
    /// so a late `onKeyValidated` could yank the user from demo into live
    /// after they had already chosen demo.
    private var isProcessing: Bool {
        validationState == .checking || keyPendingTranslationCheck != nil
    }

    private var canCheck: Bool {
        !trimmedKey.isEmpty && !isProcessing
    }

    private var statusText: String? {
        switch validationState {
        case .notChecked: return nil
        case .checking: return "Đang kiểm tra…"
        case .valid(let warning): return warning ?? "Khóa hợp lệ"
        case .invalidKey: return "Khóa không hợp lệ"
        case .unusableConfiguration: return "Khóa hợp lệ, nhưng không hỗ trợ cấu hình ngôn ngữ này."
        case .networkError: return "Lỗi mạng. Thử lại."
        }
    }

    private var statusColor: Color {
        switch validationState {
        case .valid: return Tokens.ok
        case .invalidKey, .unusableConfiguration, .networkError: return Tokens.danger
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
                guestHint: LiveLanguageConfig.default.guestHint
            )
            await MainActor.run {
                switch outcome {
                case .valid(let warning):
                    validationState = .valid(warning: warning)
                    SonioxKeychainStore.saveKey(key)
                    keyPendingTranslationCheck = key
                    Task { await beginTranslationDownloadCheck() }
                case .invalidKey:
                    validationState = .invalidKey
                case .unusableConfiguration:
                    // The key itself was accepted, but the model cannot
                    // serve the fixed vi/auto configuration - not stored,
                    // not passed on to onKeyValidated.
                    validationState = .unusableConfiguration
                case .networkError:
                    validationState = .networkError
                }
            }
        }
    }

    /// The outcome's Setup download step, right after a successful "Kiểm
    /// tra và tiếp tục", before any metered session: `.installed` continues
    /// with no prompt; `.supported` triggers `.translationTask` above (the
    /// system's own permission/progress sheet); `.unsupported`, a decline,
    /// or an error all just continue to the conversation - the live
    /// session-start check shows the banner if it is still unavailable
    /// then.
    private func beginTranslationDownloadCheck() async {
        let (source, target) = await TranslationLanguages.resolve()
        switch await LanguageAvailability().status(from: source, to: target) {
        case .installed, .unsupported:
            finishTranslationCheck()
        case .supported:
            translationDownloadConfiguration = TranslationSession.Configuration(source: source, target: target)
        @unknown default:
            finishTranslationCheck()
        }
    }

    private func finishTranslationCheck() {
        guard let key = keyPendingTranslationCheck else { return }
        keyPendingTranslationCheck = nil
        onKeyValidated(key)
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
