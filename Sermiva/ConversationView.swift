import SwiftUI
import Translation
import UIKit

/// HANDOFF.md section 2.2, "Phu de" display style only. Demo mode: the
/// `DEMO` badge is the visible marker; see docs/demo-mic-status.md for why
/// the mic dock line's dot + icon + text always report mic off here - demo
/// never opens real hardware. Generic over `SessionControlling` so the same
/// approved screen drives either `DemoSessionController` or
/// `LiveSessionController` - see `SessionControlling`.
struct ConversationView<Controller: SessionControlling>: View {
    @StateObject private var controller: Controller
    @State private var showEndSheet = false
    /// The auth-error banner's "Nhập lại khóa" action. `nil` in demo, which
    /// never reaches `.authError`. Owner-approved temporary deviation from
    /// HANDOFF section 2.2's "→ Mở Cài đặt": Settings does not exist in
    /// this outcome, so this returns to Setup instead - the only place a
    /// key can be re-entered - to be rewired to the real destination once
    /// Settings exists (see docs/soniox-routing.md).
    let onReturnToSetupAfterAuthError: (() -> Void)?

    init(controller: @autoclosure @escaping () -> Controller, onReturnToSetupAfterAuthError: (() -> Void)? = nil) {
        _controller = StateObject(wrappedValue: controller())
        self.onReturnToSetupAfterAuthError = onReturnToSetupAfterAuthError
    }

    var body: some View {
        ZStack {
            Tokens.bg.ignoresSafeArea()
            VStack(spacing: 0) {
                topBar
                if controller.state == .micDenied {
                    micDeniedBanner
                } else if controller.state == .authError {
                    authErrorBanner
                } else if controller.state == .reconnecting {
                    networkLostBanner
                } else if controller.showsNetworkErrorBanner {
                    networkErrorBanner
                } else if controller.showsTranslationUnavailableBanner {
                    translationUnavailableBanner
                }
                content
                bottomDock
            }
        }
        // Fatal-error rule 3: attached to the root ZStack, which lives for
        // the whole conversation (RootView's `.liveConversation` case;
        // sheets only ever cover it, never replace it) - never in
        // RootView. `controller.translationConfiguration` is `nil` in
        // demo, so this closure never runs there.
        .translationTask(controller.translationConfiguration) { session in
            // Fatal-error rule 1: `session` is used only here, inside this
            // closure - never stored, never passed out. Rule 4: a fresh
            // stream every time this runs, consumed sequentially (rule 5 -
            // no concurrent `translate` calls, since nothing here spawns a
            // child `Task`). Rule 6: the `for await` loop ending (the view
            // disappearing, or this task being cancelled) is exactly what
            // makes `makeTranslationRequests()`'s own stream terminate,
            // which is where queued/in-flight ids get abandoned - see
            // `MeTranslationQueue`.
            for await request in controller.makeTranslationRequests() {
                // Rule 7: "Đang dịch…" starts here, not when merely queued.
                // `false` means this request must never reach `translate` at
                // all - it is stale (already abandoned - session end,
                // availability lost) or translation is currently
                // unavailable; a request already sitting in the stream's own
                // buffer before an abandonment cannot be un-yielded, so this
                // check is what actually keeps it from being translated.
                guard controller.reportTranslationStarted(id: request.id) else { continue }
                do {
                    let response = try await session.translate(request.source)
                    controller.reportTranslationSuccess(id: request.id, target: response.targetText)
                } catch {
                    // Rule 8: every error means "no translation" - never
                    // retried automatically.
                    controller.reportTranslationFailure(id: request.id)
                }
            }
        }
        .sheet(isPresented: $showEndSheet) {
            EndSessionSheet(
                segmentCount: controller.segments.count,
                elapsed: controller.elapsed,
                bodyText: controller.endSessionBodyText,
                onConfirm: {
                    controller.endSession()
                    showEndSheet = false
                },
                onCancel: { showEndSheet = false }
            )
        }
    }

    // MARK: - Top bar

    @ScaledMetric(relativeTo: .body) private var headerSize: CGFloat = 15
    @ScaledMetric(relativeTo: .body) private var demoBadgeSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var statusTextSize: CGFloat = 12.5

    private var topBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(controller.headerText)
                    .font(.system(size: headerSize, weight: .medium))
                    .foregroundStyle(Tokens.text)
                if controller.isDemo {
                    Text("DEMO")
                        .font(.system(size: demoBadgeSize, weight: .bold))
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
                    .font(.system(size: statusTextSize, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    private var statusText: String {
        if controller.isDemo, controller.state == .listening || controller.state == .paused {
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
        return controller.isDemo ? base + " · Demo" : base
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

    @ScaledMetric(relativeTo: .body) private var bannerTextSize: CGFloat = 14

    /// Review round 3, finding 5: the prototype's own `bannerStyle`
    /// (`design/claude-handoff/Sermiva.dc.html` `~1226`) gives EVERY banner
    /// - danger/warn/net/info alike - the same padding (`10 10 10 14`, an
    /// extra 4 pt on the leading edge), margin (`4 16 6`) and inter-item gap
    /// (10); only the background (and, upstream of this modifier, the icon/
    /// text colour) depends on the variant. A single shared modifier is what
    /// keeps that in sync across all four banners below, rather than four
    /// independently-hand-copied constants that can drift.
    private struct BannerStyle: ViewModifier {
        let background: Color
        func body(content: Content) -> some View {
            content
                .padding(.leading, 14)
                .padding(.top, 10)
                .padding(.trailing, 10)
                .padding(.bottom, 10)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 6)
        }
    }

    private var micDeniedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Tokens.danger)
            Text("Sermiva chưa được cấp quyền micro.")
                .font(.system(size: bannerTextSize))
                .foregroundStyle(Tokens.danger)
            Spacer()
            Button("Mở Cài đặt iPhone") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.system(size: bannerTextSize, weight: .semibold))
            .foregroundStyle(Tokens.danger)
        }
        .modifier(BannerStyle(background: Tokens.surface2))
    }

    /// HANDOFF.md section 2.2's "lỗi xác thực (→ Mở Cài đặt)" banner.
    /// Approved temporary deviation: its action opens the app's own
    /// Settings screen, which this outcome does not build, so this returns
    /// to Setup instead - the only in-app place a key can be re-entered -
    /// to be rewired to Settings once it exists (see
    /// docs/soniox-routing.md). The message reuses `SetupView`'s own
    /// existing "Khóa không hợp lệ" copy rather than inventing new text.
    private var authErrorBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Tokens.danger)
            Text("Khóa không hợp lệ.")
                .font(.system(size: bannerTextSize))
                .foregroundStyle(Tokens.danger)
            Spacer()
            Button("Nhập lại khóa") {
                onReturnToSetupAfterAuthError?()
            }
            .font(.system(size: bannerTextSize, weight: .semibold))
            .foregroundStyle(Tokens.danger)
        }
        .modifier(BannerStyle(background: Tokens.surface2))
    }

    /// HANDOFF.md section 2.2's "mất mạng (spinner, 'nội dung được giữ')"
    /// banner, verbatim: a spinner plus that exact quoted text - no new
    /// copy invented beyond what the handoff already specifies.
    private var networkLostBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(Tokens.warn)
            Text("Mất mạng. Nội dung được giữ.")
                .font(.system(size: bannerTextSize))
                .foregroundStyle(Tokens.text2)
            Spacer()
        }
        .modifier(BannerStyle(background: Tokens.surface2))
    }

    /// Review round 4, finding 5: the approved prototype's own network-error
    /// string (`design/claude-handoff/Sermiva.dc.html` `~810`, Settings key
    /// status `network`), reused verbatim - no new copy - for the FIRST
    /// connect of a session attempt failing for a non-auth reason. Never
    /// shown for a mid-session reconnect (that already has `networkLostBanner`
    /// above), and cleared only once a later attempt actually succeeds.
    private var networkErrorBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle")
                .foregroundStyle(Tokens.danger)
            Text("Lỗi mạng, thử lại sau")
                .font(.system(size: bannerTextSize))
                .foregroundStyle(Tokens.danger)
            Spacer()
        }
        .modifier(BannerStyle(background: Tokens.surface2))
    }

    /// The banner shown from a live session's start-of-session availability
    /// check (`.installed` fails) through the rest of that session, per
    /// docs/soniox-routing.md. This is HANDOFF 2.2's "info" banner variant,
    /// not the danger/warn style the other three above use - the prototype
    /// gives it `surface` (not `surface2`) background and `text2` (not
    /// `text3`) icon/text colour; the geometry itself (padding/margin/gap)
    /// is identical to every other banner - see `BannerStyle` above.
    /// `controller.showsTranslationUnavailableBanner` is always `false` in
    /// demo, so this never shows there.
    private var translationUnavailableBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(Tokens.text2)
            Text("Lời của Bạn sẽ không được dịch sang tiếng Anh trên máy này.")
                .font(.system(size: bannerTextSize))
                .foregroundStyle(Tokens.text2)
            Spacer()
        }
        .modifier(BannerStyle(background: Tokens.surface))
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if controller.segments.isEmpty {
            emptyState
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            CaptionsTranscriptView(displaySegments: controller.displaySegments)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Real capture, not session progress: showing "Dang nghe..." here
    /// while the mic never actually opened would be exactly the kind of
    /// state AGENTS.md forbids.
    private var isEmptyListening: Bool { controller.isMicCapturing }

    @ScaledMetric(relativeTo: .body) private var emptyTitleSize: CGFloat = 17
    @ScaledMetric(relativeTo: .body) private var emptyBodySize: CGFloat = 14

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            if isEmptyListening {
                HStack(spacing: 6) {
                    Circle().fill(Tokens.live).frame(width: 8, height: 8)
                    Text("Đang nghe…")
                        .font(.system(size: emptyTitleSize, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                }
                Text("Chưa có lời nói. Cứ nói tự nhiên, nguyên văn và bản dịch sẽ hiện ở đây.")
                    .font(.system(size: emptyBodySize))
                    .foregroundStyle(Tokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            } else {
                Text("Sẵn sàng bắt đầu")
                    .font(.system(size: emptyTitleSize, weight: .semibold))
                    .foregroundStyle(Tokens.text)
                Text("Đặt iPhone giữa hai người và nhấn Bắt đầu một lần. App nghe liên tục và dịch hai chiều, không cần giữ nút hay chọn người nói.")
                    .font(.system(size: emptyBodySize))
                    .foregroundStyle(Tokens.text2)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            Spacer()
            Spacer()
        }
    }

    // MARK: - Bottom dock

    /// The view reads the already-computed result from the controller - the
    /// single source for the demo-vs-live decision - rather than passing its
    /// own `isDemo` flag into a text-computing call here.
    private var micDockText: String { controller.micDockText }

    /// Pure so the role-to-color mapping is directly testable: demo must
    /// never reach `.live` (the "listening" red), and this is the one place
    /// that decides what color that role actually renders as.
    static func micDotColor(for role: SessionPresentation.MicDotColorRole) -> Color {
        switch role {
        case .neutral: return Tokens.text3
        case .warn: return Tokens.warn
        case .live: return Tokens.live
        }
    }

    private var micDotColor: Color { Self.micDotColor(for: controller.micDotColorRole) }

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

    @ScaledMetric(relativeTo: .body) private var micDockTextSize: CGFloat = 12.5
    @ScaledMetric(relativeTo: .body) private var pillButtonSize: CGFloat = 17

    private var bottomDock: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(micDotColor)
                    .frame(width: 8, height: 8)
                Image(systemName: controller.micIconName)
                    .font(.system(size: micDockTextSize))
                    .foregroundStyle(Tokens.text2)
                    // SF Symbols carry their own VoiceOver label (e.g. "Tắt
                    // Micrô" for mic.slash), which would announce this line
                    // twice and read like a tappable control. The text next
                    // to it already says the same state in words - hide the
                    // icon from accessibility so the line is read once.
                    .accessibilityHidden(true)
                Text(micDockText)
                    .font(.system(size: micDockTextSize, weight: .semibold))
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
                            .font(.system(size: pillButtonSize, weight: .semibold))
                            .frame(minWidth: 44, minHeight: 50)
                            .padding(.horizontal, 14)
                    }
                }
                .background(primaryIsOk ? Tokens.ok : Tokens.accent)
                .foregroundStyle(Tokens.onAccent)
                .clipShape(Capsule())
                .disabled(primaryDisabled)
                .opacity(primaryDisabled ? 0.4 : 1)
                .accessibilityIdentifier("primaryButton")

                Button(action: { showEndSheet = true }) {
                    Text("Kết thúc")
                        .font(.system(size: pillButtonSize, weight: .semibold))
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

extension ConversationView where Controller == DemoSessionController {
    init(events: [DemoEvent], isDemo: Bool, languageConfig: LiveLanguageConfig = .default) {
        self.init(controller: DemoSessionController(events: events, isDemo: isDemo, languageConfig: languageConfig))
    }
}

private struct LabeledRoundButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var labelSize: CGFloat = 11

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: systemImage)
                    .frame(width: 44, height: 44)
                Text(label)
                    .font(.system(size: labelSize, weight: .medium))
            }
        }
        .foregroundStyle(Tokens.text2)
    }
}
