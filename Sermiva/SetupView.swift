import SwiftUI

/// HANDOFF.md section 2.1. Only enough to reach demo mode: the real-key
/// path ("Kiem tra va tiep tuc") is visible per the approved layout but
/// disabled, since validating a real Soniox key is out of scope here.
struct SetupView: View {
    let onStartDemo: () -> Void

    @State private var apiKey: String = ""
    @State private var isKeyVisible = false

    @ScaledMetric(relativeTo: .body) private var titleSize: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var bodySize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var buttonSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var demoButtonSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var footerSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var fieldSize: CGFloat = 16

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

                Button(action: {}) {
                    Text("Kiểm tra và tiếp tục")
                        .font(.system(size: buttonSize, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .background(Tokens.accent.opacity(0.5))
                .foregroundStyle(Tokens.onAccent)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .disabled(true)
                .padding(.horizontal, 20)

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
