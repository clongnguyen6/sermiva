import SwiftUI
import UIKit

/// HANDOFF.md section 2.2, "Phu de" display style only. Demo mode: the
/// `DEMO` badge is the visible marker; see docs/demo-mic-status.md for why
/// the mic dock line still says "Dang nghe" truthfully during playback.
struct ConversationView: View {
    @StateObject private var controller: DemoSessionController
    @State private var showEndSheet = false
    let isDemo: Bool

    init(events: [DemoEvent], isDemo: Bool) {
        _controller = StateObject(wrappedValue: DemoSessionController(events: events))
        self.isDemo = isDemo
    }

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if controller.state == .micDenied {
                    micDeniedBanner
                }
                content
                bottomDock
            }
        }
        .sheet(isPresented: $showEndSheet) {
            EndSessionSheet(
                segmentCount: controller.segments.count,
                elapsed: controller.elapsed,
                onConfirm: {
                    controller.endSession()
                    showEndSheet = false
                },
                onCancel: { showEndSheet = false }
            )
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Tiếng Việt ↔ Tiếng Anh")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Tokens.text)
                if isDemo {
                    Text("DEMO")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Tokens.warn.opacity(0.18))
                        .foregroundStyle(Tokens.warn)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                Spacer()
                Button(action: {}) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Tokens.text2)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Cài đặt")
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var statusText: String {
        if isDemo, controller.state == .listening || controller.state == .paused {
            return "Phiên mô phỏng"
        }
        let base: String
        switch controller.state {
        case .idle: base = "Sẵn sàng"
        case .requestingMic, .connecting: base = "Đang kết nối…"
        case .listening: base = "Đã kết nối"
        case .paused: base = "Tạm dừng"
        case .reconnecting: base = "Đang kết nối lại…"
        case .authError: base = "Lỗi xác thực"
        case .micDenied: base = "Cần quyền micro"
        case .ended: base = "Đã kết thúc"
        }
        return isDemo ? base + " · Demo" : base
    }

    private var statusColor: Color {
        switch controller.state {
        case .listening: return Tokens.ok
        case .connecting, .requestingMic, .reconnecting: return Tokens.warn
        case .authError, .micDenied: return Tokens.danger
        case .idle, .paused, .ended: return Tokens.text3
        }
    }

    // MARK: - Banner

    private var micDeniedBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Tokens.danger)
            Text("Sermiva chưa được cấp quyền micro.")
                .font(.system(size: 14))
                .foregroundStyle(Tokens.danger)
            Spacer()
            Button("Mở Cài đặt iPhone") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Tokens.danger)
        }
        .padding(10)
        .background(Tokens.surface2)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if controller.segments.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CaptionsTranscriptView(segments: controller.segments)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Real capture, not session progress: showing "Dang nghe..." here
    /// while the mic never actually opened would be exactly the kind of
    /// state AGENTS.md forbids.
    private var isEmptyListening: Bool { controller.isMicCapturing }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if isEmptyListening {
                HStack(spacing: 6) {
                    Circle().fill(Tokens.live).frame(width: 8, height: 8)
                    Text("Đang nghe…")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                }
                Text("Chưa có lời nói. Cứ nói tự nhiên, nguyên văn và bản dịch sẽ hiện ở đây.")
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("Sẵn sàng bắt đầu")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text("Đặt iPhone giữa hai người và nhấn Bắt đầu một lần. App nghe liên tục và dịch hai chiều, không cần giữ nút hay chọn người nói.")
                    .font(.system(size: 14))
                    .foregroundStyle(Tokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Spacer()
        }
    }

    // MARK: - Bottom dock

    private var micDockText: String {
        DemoSessionController.micDockText(isMicCapturing: controller.isMicCapturing, state: controller.state)
    }

    private var micOn: Bool { controller.isMicCapturing }

    private var primaryLabel: String {
        switch controller.state {
        case .idle, .micDenied, .authError: return "Bắt đầu"
        case .listening, .reconnecting: return "Tạm dừng"
        case .paused: return "Tiếp tục"
        case .connecting, .requestingMic: return ""
        case .ended: return "Phiên mới"
        }
    }

    private var primaryDisabled: Bool {
        switch controller.state {
        case .connecting, .requestingMic, .authError: return true
        default: return false
        }
    }

    private var primaryIsOk: Bool { controller.state == .paused }

    private var bottomDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(micOn ? Tokens.live : (controller.state == .connecting || controller.state == .requestingMic ? Tokens.warn : Tokens.text3))
                    .frame(width: 8, height: 8)
                Text(micDockText)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Tokens.surface)
            .clipShape(RoundedRectangle(cornerRadius: 22))

            HStack(spacing: 8) {
                LabeledRoundButton(systemImage: "textformat.size", label: "Cỡ chữ", action: {})
                LabeledRoundButton(systemImage: "rectangle.3.group", label: "Hiển thị", action: {})

                Spacer()

                Button(action: controller.primaryButtonTapped) {
                    if controller.state == .connecting || controller.state == .requestingMic {
                        ProgressView().tint(Tokens.onAccent)
                            .frame(minWidth: 44, minHeight: 50)
                    } else {
                        Text(primaryLabel)
                            .font(.system(size: 17, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 50)
                            .padding(.horizontal, 14)
                    }
                }
                .background(primaryIsOk ? Tokens.ok : Tokens.accent)
                .foregroundStyle(Tokens.onAccent)
                .clipShape(Capsule())
                .disabled(primaryDisabled)
                .opacity(primaryDisabled ? 0.4 : 1)

                Button(action: { showEndSheet = true }) {
                    Text("Kết thúc")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(minWidth: 44, minHeight: 50)
                        .padding(.horizontal, 14)
                }
                .background(Tokens.danger)
                .foregroundStyle(Color.white)
                .clipShape(Capsule())
                .disabled(!controller.canEnd)
                .opacity(controller.canEnd ? 1 : 0.4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial)
    }
}

private struct LabeledRoundButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .frame(width: 44, height: 44)
                Text(label)
                    .font(.system(size: 11, weight: .medium))
            }
        }
        .foregroundStyle(Tokens.text2)
    }
}
