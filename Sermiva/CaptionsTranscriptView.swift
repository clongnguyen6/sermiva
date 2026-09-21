import SwiftUI

/// The "Phu de" (captions) display style, HANDOFF.md section 3 and the
/// approved prototype (`Sermiva.dc.html`, read-only): everything
/// left-aligned, the current sentence on a raised surface with a 3pt accent
/// bar, history rows smaller and separated by dividers.
struct CaptionsTranscriptView: View {
    let segments: [Segment]
    /// Whether recognition/translation is genuinely running right now - see
    /// `DemoSessionController.isActivityRunning`. Gates every "in progress"
    /// indicator below; it does not affect what content is shown, only
    /// whether the view claims something is actively happening.
    let isActivityRunning: Bool

    private var current: Segment? { segments.last }
    private var history: ArraySlice<Segment> { segments.dropLast() }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(history), id: \.id) { segment in
                        HistoryRow(segment: segment, isActivityRunning: isActivityRunning)
                        if segment.id != history.last?.id {
                            Rectangle().fill(Tokens.sep).frame(height: 0.5)
                        }
                    }
                    if let current {
                        CurrentRow(segment: current, isActivityRunning: isActivityRunning)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            // Watches the whole array, not just the last id: a partial
            // growing, a final locking, or a target arriving all change the
            // current row's height without changing its id, and the last
            // sentence must always show in full above the dock.
            .onChange(of: segments) { _, newSegments in
                guard let lastId = newSegments.last?.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
}

private struct CurrentRow: View {
    let segment: Segment
    let isActivityRunning: Bool
    @ScaledMetric(relativeTo: .body) private var metaSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var srcSize: CGFloat = 16
    @ScaledMetric(relativeTo: .body) private var tgtSize: CGFloat = 24

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    SegmentMeta(segment: segment, fontSize: metaSize)
                    CurrentStatusTag(segment: segment, isActivityRunning: isActivityRunning)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .bottom, spacing: 0) {
                    Text(segment.source)
                        .font(.system(size: srcSize))
                        .foregroundStyle(Tokens.text2)
                    if !segment.isFinal && isActivityRunning {
                        BlinkingCaret()
                    }
                }
                if let target = segment.target {
                    Text(target)
                        .font(.system(size: tgtSize, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                } else if segment.isFinal && isActivityRunning {
                    TranslatingPlaceholder(fontSize: metaSize)
                }
            }
            .padding(.leading, 12)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        // `scrollTo(anchor: .bottom)` aligns this view's own bottom edge to
        // the viewport - trailing space added by the outer VStack's padding
        // sits past that edge and never becomes visible. The margin has to
        // live inside the identified view itself, so it actually shows.
        .padding(.bottom, 16)
        .id(segment.id)
        // Without this, SwiftUI never creates one addressable element for
        // the whole card - `.accessibilityIdentifier` lands on whichever
        // child Text happens to claim it instead. `.contain` groups the
        // card into one element while still exposing each child
        // individually to VoiceOver, so nothing it reads changes.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("currentSegment")
        .accessibilityAddTraits((segment.isFinal || !isActivityRunning) ? [] : .updatesFrequently)
    }
}

private struct HistoryRow: View {
    let segment: Segment
    let isActivityRunning: Bool
    @ScaledMetric(relativeTo: .body) private var metaSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var srcSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var tgtSize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SegmentMeta(segment: segment, fontSize: metaSize)
            Text(segment.source)
                .font(.system(size: srcSize))
                .foregroundStyle(Tokens.text2)
            if let target = segment.target {
                Text(target)
                    .font(.system(size: tgtSize, weight: .medium))
                    .foregroundStyle(Tokens.text)
            } else if segment.isFinal && isActivityRunning {
                TranslatingPlaceholder(fontSize: metaSize)
            }
        }
    }
}

/// The uppercase meta line - speaker label, language, "Noi chong" - shared
/// by history and current rows. HANDOFF.md section 9's `SegmentHeader`,
/// minus the recognizing/done tag, which only the current row shows
/// (`CurrentStatusTag`) and which the prototype explicitly keeps out of the
/// uppercase transform.
private struct SegmentMeta: View {
    let segment: Segment
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            speakerLabel
            Text(languageText)
            if segment.overlap {
                Text("Nói chồng")
                    .foregroundStyle(Tokens.warn)
            }
        }
        .font(.system(size: fontSize, weight: .semibold))
        .tracking(fontSize * 0.02)
        .textCase(.uppercase)
        .foregroundStyle(Tokens.text3)
    }

    @ViewBuilder
    private var speakerLabel: some View {
        switch segment.speaker {
        case "A":
            Text("Người nói A").foregroundStyle(Tokens.speakerA)
        case "B":
            Text("Người nói B").foregroundStyle(Tokens.speakerB)
        default:
            Text("Chưa xác định")
        }
    }

    private var languageText: String {
        segment.lang.map(LanguageNames.display) ?? "Đang nhận diện ngôn ngữ"
    }
}

/// "Dang nhan dang" (pulsing dot) while partial and genuinely running,
/// "Hoan tat" (checkmark) once a target has landed - the latter is a
/// completed fact, not a claim of ongoing activity, so it does not need
/// `isActivityRunning`. Explicitly not uppercase, and only ever shown on
/// the current row - the prototype has no such tag on history rows.
private struct CurrentStatusTag: View {
    let segment: Segment
    let isActivityRunning: Bool
    @ScaledMetric(relativeTo: .body) private var tagSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var checkmarkSize: CGFloat = 10

    var body: some View {
        if !segment.isFinal && isActivityRunning {
            HStack(spacing: 5) {
                PulsingDot(color: Tokens.accent)
                Text("Đang nhận dạng")
            }
            .font(.system(size: tagSize, weight: .semibold))
            .foregroundStyle(Tokens.accent)
        } else if segment.target != nil {
            HStack(spacing: 4) {
                Image(systemName: "checkmark")
                    .font(.system(size: checkmarkSize, weight: .bold))
                Text("Hoàn tất")
            }
            .font(.system(size: tagSize, weight: .medium))
            .foregroundStyle(Tokens.text3)
        }
    }
}

/// The one and only "Dang dich..." placeholder: a small fixed-size row in
/// the body, below the source text, shown once (never duplicated in the
/// header too) while a final segment has no target yet.
private struct TranslatingPlaceholder: View {
    let fontSize: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            ProgressView().scaleEffect(0.55)
            Text("Đang dịch…")
        }
        .font(.system(size: fontSize, weight: .medium))
        .foregroundStyle(Tokens.text3)
    }
}

private struct PulsingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let color: Color
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.35 : 1)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    dim = true
                }
            }
    }
}

/// The caret after a partial's live source text, HANDOFF.md section 6.
private struct BlinkingCaret: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hidden = false

    var body: some View {
        Rectangle()
            .fill(Tokens.accent)
            .frame(width: 2, height: 14)
            .opacity(hidden ? 0 : 1)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.linear(duration: 0.6).repeatForever(autoreverses: true)) {
                    hidden = true
                }
            }
    }
}

enum LanguageNames {
    private static let names: [String: String] = [
        "vi": "Tiếng Việt",
        "en": "Tiếng Anh",
    ]

    static func display(for code: String) -> String {
        names[code] ?? code.uppercased()
    }
}
