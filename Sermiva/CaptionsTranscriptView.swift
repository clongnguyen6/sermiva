import SwiftUI

/// The "Phu de" (captions) display style, HANDOFF.md section 3 and the
/// approved prototype (`Sermiva.dc.html`, read-only): everything
/// left-aligned, the current sentence on a raised surface with a 3pt accent
/// bar, history rows smaller and separated by dividers.
struct CaptionsTranscriptView: View {
    let displaySegments: [SegmentDisplay]

    private var current: SegmentDisplay? { displaySegments.last }
    private var history: ArraySlice<SegmentDisplay> { displaySegments.dropLast() }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(history), id: \.segment.id) { display in
                        HistoryRow(display: display)
                        if display.segment.id != history.last?.segment.id {
                            Rectangle().fill(Tokens.sep).frame(height: 0.5)
                        }
                    }
                    if let current {
                        CurrentRow(display: current)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            // Watches the whole array, not just the last id: a partial
            // growing, a final locking, or a target arriving all change the
            // current row's height without changing its id, and the last
            // sentence must always show in full above the dock.
            .onChange(of: displaySegments) { _, newDisplaySegments in
                guard let lastId = newDisplaySegments.last?.segment.id else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
}

private struct CurrentRow: View {
    let display: SegmentDisplay
    private var segment: Segment { display.segment }
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
                    SegmentMeta(display: display, fontSize: metaSize)
                    CurrentStatusTag(display: display)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .bottom, spacing: 0) {
                    Text(display.sourceText)
                        .font(.system(size: srcSize))
                        .foregroundStyle(Tokens.text2)
                    if display.showsCaret {
                        BlinkingCaret()
                    }
                }
                if let targetText = display.targetText {
                    Text(targetText)
                        .font(.system(size: tgtSize, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                } else if display.showsTranslatingPlaceholder {
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
        .accessibilityAddTraits(display.updatesFrequently ? .updatesFrequently : [])
    }
}

private struct HistoryRow: View {
    let display: SegmentDisplay
    private var segment: Segment { display.segment }
    @ScaledMetric(relativeTo: .body) private var metaSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var srcSize: CGFloat = 14
    @ScaledMetric(relativeTo: .body) private var tgtSize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SegmentMeta(display: display, fontSize: metaSize)
            Text(display.sourceText)
                .font(.system(size: srcSize))
                .foregroundStyle(Tokens.text2)
            if let targetText = display.targetText {
                Text(targetText)
                    .font(.system(size: tgtSize, weight: .medium))
                    .foregroundStyle(Tokens.text)
            } else if display.showsTranslatingPlaceholder {
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
    let display: SegmentDisplay
    let fontSize: CGFloat
    private var segment: Segment { display.segment }

    var body: some View {
        HStack(spacing: 6) {
            speakerLabel
            if let languageText = display.languageText {
                Text(languageText)
            }
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

    private var speakerLabel: some View {
        Text(SpeakerLabel.text(for: segment.speaker))
            .foregroundStyle(speakerLabelColor)
    }

    private var speakerLabelColor: Color {
        switch SpeakerLabel.colorRole(for: segment.speaker) {
        case .speakerA: return Tokens.speakerA
        case .speakerB: return Tokens.speakerB
        case .other: return Tokens.text2
        case .unidentified: return Tokens.text3
        }
    }
}

/// The A/B/C.../"Chưa xác định" speaker label rule, owner-decided: every
/// diarized speaker beyond A/B is a real, distinct person and must show its
/// own "Người nói <letter>" label - AGENTS.md forbids merging different
/// real speakers under "Chưa xác định" just because there are more than
/// two. `SonioxJoinEngine.label(forRawSpeaker:)` only ever assigns single
/// uppercase letters A through Z, so any non-nil `speaker` here is always
/// one of those. Pure and SwiftUI-free so it is directly testable.
enum SpeakerLabel {
    enum ColorRole: Equatable {
        case speakerA, speakerB, other, unidentified
    }

    static func text(for speaker: String?) -> String {
        guard let speaker else { return "Chưa xác định" }
        return "Người nói \(speaker)"
    }

    static func colorRole(for speaker: String?) -> ColorRole {
        switch speaker {
        case "A": return .speakerA
        case "B": return .speakerB
        case .some: return .other
        case nil: return .unidentified
        }
    }
}

/// "Dang nhan dang" (pulsing dot) while partial and genuinely running,
/// "Hoan tat" (checkmark) once a target has landed - the latter is a
/// completed fact, not a claim of ongoing activity, so it does not need
/// `isActivityRunning`. Explicitly not uppercase, and only ever shown on
/// the current row - the prototype has no such tag on history rows.
private struct CurrentStatusTag: View {
    let display: SegmentDisplay
    @ScaledMetric(relativeTo: .body) private var tagSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var checkmarkSize: CGFloat = 10

    var body: some View {
        if display.showsRecognizingTag {
            HStack(spacing: 5) {
                PulsingDot(color: Tokens.accent)
                Text("Đang nhận dạng")
            }
            .font(.system(size: tagSize, weight: .semibold))
            .foregroundStyle(Tokens.accent)
        } else if display.segment.target != nil {
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
