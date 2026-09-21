import SwiftUI

/// The "Phu de" (captions) display style, HANDOFF.md section 3: everything
/// left-aligned, the current sentence on a raised surface with a 3pt accent
/// bar, history rows smaller and separated by dividers.
struct CaptionsTranscriptView: View {
    let segments: [Segment]

    private var current: Segment? { segments.last }
    private var history: ArraySlice<Segment> { segments.dropLast() }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(history), id: \.id) { segment in
                        HistoryRow(segment: segment)
                        if segment.id != history.last?.id {
                            Rectangle().fill(Tokens.sep).frame(height: 0.5)
                        }
                    }
                    if let current {
                        CurrentRow(segment: current)
                            .id(current.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .onChange(of: segments.last?.id) { _, newId in
                guard let newId else { return }
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(newId, anchor: .bottom)
                }
            }
        }
    }
}

private struct CurrentRow: View {
    let segment: Segment

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(Tokens.accent)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                SegmentHeader(segment: segment)
                Text(segment.source)
                    .font(.system(size: 16))
                    .foregroundStyle(Tokens.text2)
                if let target = segment.target {
                    Text(target)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(Tokens.text)
                } else if segment.isFinal {
                    TranslatingLabel()
                }
            }
            .padding(.leading, 12)
        }
        .padding(.vertical, 10)
        .padding(.trailing, 12)
        .background(Tokens.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}

private struct HistoryRow: View {
    let segment: Segment

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            SegmentHeader(segment: segment)
            Text(segment.source)
                .font(.system(size: 14))
                .foregroundStyle(Tokens.text2)
            if let target = segment.target {
                Text(target)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Tokens.text)
            }
        }
    }
}

/// Speaker label, language, "Noi chong" and the recognizing/translating/done
/// tag - HANDOFF.md section 9's `SegmentHeader`.
private struct SegmentHeader: View {
    let segment: Segment

    var body: some View {
        HStack(spacing: 8) {
            speakerLabel
            if let lang = segment.lang {
                Text(LanguageNames.display(for: lang))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.text3)
                    .textCase(.uppercase)
            }
            if segment.overlap {
                Text("Nói chồng")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Tokens.warn)
            }
            Spacer(minLength: 0)
            statusTag
        }
    }

    @ViewBuilder
    private var speakerLabel: some View {
        switch segment.speaker {
        case "A":
            Text("A").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.speakerA)
        case "B":
            Text("B").font(.system(size: 12, weight: .semibold)).foregroundStyle(Tokens.speakerB)
        default:
            Text("Chưa xác định")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.text3)
        }
    }

    @ViewBuilder
    private var statusTag: some View {
        if !segment.isFinal {
            Text("Đang nhận dạng")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.accent)
        } else if segment.target == nil {
            TranslatingLabel()
        } else {
            Text("Hoàn tất")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Tokens.text3)
        }
    }
}

private struct TranslatingLabel: View {
    var body: some View {
        HStack(spacing: 4) {
            ProgressView().scaleEffect(0.6)
            Text("Đang dịch…")
                .font(.system(size: 12, weight: .semibold))
        }
        .foregroundStyle(Tokens.text3)
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
