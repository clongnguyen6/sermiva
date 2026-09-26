import SwiftUI

/// Pure per-pane content decision for HANDOFF.md section 3's "Đối diện"
/// style: which text each reader sees for the single latest segment. No
/// SwiftUI, so every branch - including the two "nothing exists to show"
/// cases this must never invent text for - is directly testable without a
/// session or a view.
struct FacingPaneContent: Equatable {
    let readerLabel: String
    let hasSegment: Bool
    let speakerText: String
    let speakerColorRole: SpeakerLabel.ColorRole
    let isPartial: Bool
    /// `nil` means nothing to show at this position - never fallback text.
    let big: String?
    let isTranslatingBig: Bool
    /// Same "nil means nothing" rule as `big`.
    let small: String?

    /// `me`/`target` are `LiveLanguageConfig`'s two fixed language codes
    /// (`LiveSessionController.meLanguage`/`.targetLanguage`); `latest` is
    /// the single most recent `SegmentDisplay`, the same one both panes
    /// read - Facing shows only the latest sentence, never a history.
    static func make(readerLanguage: String, me: String, target: String, latest: SegmentDisplay?) -> FacingPaneContent {
        let readerLabel = Self.readerLabel(for: readerLanguage)
        guard let latest else {
            return FacingPaneContent(readerLabel: readerLabel, hasSegment: false, speakerText: "", speakerColorRole: .unidentified, isPartial: false, big: nil, isTranslatingBig: false, small: nil)
        }
        let segment = latest.segment
        let speakerText = SpeakerLabel.text(for: segment.speaker)
        let speakerColorRole = SpeakerLabel.colorRole(for: segment.speaker)
        let isPartial = latest.showsRecognizingTag

        // `lang == nil` means diarization has not identified a language for
        // this segment yet - not "definitely some other language". Routing
        // a translation destination off that unknown would be a guess, so
        // it is handled by the same no-invent fallback as a genuine
        // third-language guest below, never folded into the `me`/`target`
        // comparison.
        if let lang = segment.lang {
            if lang == readerLanguage {
                // This reader's own language: the original text already
                // reads fine for them, at full size; their counterpart's
                // language, if it has arrived, is the small supplementary
                // line.
                return FacingPaneContent(readerLabel: readerLabel, hasSegment: true, speakerText: speakerText, speakerColorRole: speakerColorRole, isPartial: isPartial, big: latest.sourceText, isTranslatingBig: false, small: latest.targetText)
            }

            // docs/soniox-routing.md: a `me`-language segment's translation
            // lands in `target`; every other segment's lands in `me`,
            // regardless of its actual language - that one fixed direction
            // is the only translation this app ever requests. A translation
            // usable as this reader's big line only exists - now or ever -
            // when readerLanguage is that fixed destination.
            let translationDestination = lang == me ? target : me
            if translationDestination == readerLanguage {
                return FacingPaneContent(readerLabel: readerLabel, hasSegment: true, speakerText: speakerText, speakerColorRole: speakerColorRole, isPartial: isPartial, big: latest.targetText, isTranslatingBig: latest.showsTranslatingPlaceholder, small: latest.sourceText)
            }
        }

        // Neither branch above applies: the segment's language is not yet
        // identified, or the guest is speaking a third language that is
        // neither `me` nor `target`. No translation into readerLanguage has
        // ever been requested for this segment and none ever will be -
        // showing one here would be inventing text, and reusing the single
        // `target` field (which, by the branch above, is in some OTHER
        // language) would silently mislabel it as this reader's own. Per
        // AGENTS.md, show only what genuinely exists: the segment's real
        // words, verbatim, with no supplementary line (the only other field
        // that exists is in neither this reader's language nor the
        // segment's own).
        return FacingPaneContent(readerLabel: readerLabel, hasSegment: true, speakerText: speakerText, speakerColorRole: speakerColorRole, isPartial: isPartial, big: latest.sourceText, isTranslatingBig: false, small: nil)
    }

    /// `t.facing.readVi` / `t.facing.readEn` / `t.facing.reads + langName`,
    /// verbatim from the approved prototype.
    private static func readerLabel(for language: String) -> String {
        switch language {
        case "vi": return "Đọc tiếng Việt"
        case "en": return "Đọc English"
        default: return "Đọc " + LanguageNames.display(for: language)
        }
    }
}

/// HANDOFF.md section 3's "Đối diện" display style: two reading regions
/// sharing the session's own segments and controls - switching into or out
/// of it never touches the mic or the session (criterion 1). The top region
/// is rotated 180° so the person sitting across the table reads it
/// right-side-up; the fixed middle strip (mic · Tạm dừng/Tiếp tục · Đổi bên
/// · ✕) is the only place a person on either side can act.
struct FacingTranscriptView: View {
    let displaySegments: [SegmentDisplay]
    let meLanguage: String
    let targetLanguage: String
    @Binding var swapped: Bool
    let micDockText: String
    let micDotColor: Color
    let micIconName: String
    let primaryLabel: String
    let primaryDisabled: Bool
    let primaryIsOk: Bool
    let isConnecting: Bool
    let onPrimary: () -> Void
    let onExit: () -> Void

    private var latest: SegmentDisplay? { displaySegments.last }
    private var topLanguage: String { swapped ? meLanguage : targetLanguage }
    private var bottomLanguage: String { swapped ? targetLanguage : meLanguage }

    private var topContent: FacingPaneContent {
        FacingPaneContent.make(readerLanguage: topLanguage, me: meLanguage, target: targetLanguage, latest: latest)
    }

    private var bottomContent: FacingPaneContent {
        FacingPaneContent.make(readerLanguage: bottomLanguage, me: meLanguage, target: targetLanguage, latest: latest)
    }

    var body: some View {
        GeometryReader { geo in
            // HANDOFF section 3: fixed insets on the non-rotated wrapper -
            // top stays 54 pt in both orientations (the device frame's own
            // status bar/island sits at the top either way); the bottom
            // shrinks in landscape, where the notch moves to the side.
            let isLandscape = geo.size.width > geo.size.height
            VStack(spacing: 0) {
                FacingPane(content: topContent, identifierPrefix: "facingTop")
                    .rotationEffect(.degrees(180))
                    .padding(.top, 54)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                middleStrip

                FacingPane(content: bottomContent, identifierPrefix: "facingBottom")
                    .padding(.bottom, isLandscape ? 22 : 34)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .background(Tokens.bg)
    }

    @ScaledMetric(relativeTo: .body) private var micTextSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var stripLabelSize: CGFloat = 14

    private var showsPauseIcon: Bool { primaryLabel == "Tạm dừng" }

    private var middleStrip: some View {
        HStack(spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(micDotColor).frame(width: 8, height: 8)
                Image(systemName: micIconName)
                    .font(.system(size: micTextSize))
                    .foregroundStyle(Tokens.text2)
                    .accessibilityHidden(true)
                Text(micDockText)
                    .font(.system(size: micTextSize, weight: .semibold))
                    .foregroundStyle(Tokens.text2)
                    .lineLimit(1)
            }
            .frame(minHeight: 44)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: onPrimary) {
                HStack(spacing: 6) {
                    if isConnecting {
                        ProgressView().tint(Tokens.onAccent)
                    } else {
                        Image(systemName: showsPauseIcon ? "pause.fill" : "play.fill")
                            .font(.system(size: 13))
                        Text(primaryLabel)
                            .font(.system(size: stripLabelSize, weight: .semibold))
                    }
                }
                .frame(minWidth: 44, minHeight: 44)
                .padding(.horizontal, 14)
            }
            .background(primaryIsOk ? Tokens.ok : Tokens.accent)
            .foregroundStyle(Tokens.onAccent)
            .clipShape(Capsule())
            .disabled(primaryDisabled)
            .opacity(primaryDisabled ? 0.4 : 1)
            .accessibilityIdentifier("facingPrimaryButton")

            Button(action: { swapped.toggle() }) {
                // Fixed at the prototype's own icon size (`Sermiva.dc.html`
                // swapFacing button, `svg width="20"`) rather than an
                // unscaled default - at the maximum accessibility text size,
                // `Image(systemName:)` without an explicit size otherwise
                // grows past this 44 pt circle and clips into an unreadable
                // glyph.
                Image(systemName: "arrow.up.arrow.down")
                    .font(.system(size: 20))
                    .foregroundStyle(Tokens.text)
                    .frame(width: 44, height: 44)
            }
            .background(Tokens.surface2)
            .clipShape(Circle())
            .accessibilityLabel("Đổi bên")
            .accessibilityIdentifier("facingSwapButton")

            Button(action: onExit) {
                // Same reasoning as the swap icon above; 18 pt matches the
                // prototype's own `exitStage`/xmark `svg width="18"`.
                Image(systemName: "xmark")
                    .font(.system(size: 18))
                    .foregroundStyle(Tokens.text)
                    .frame(width: 44, height: 44)
            }
            .background(Tokens.surface2)
            .clipShape(Circle())
            .accessibilityLabel("Thoát Sân khấu")
            .accessibilityIdentifier("facingExitButton")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Tokens.surface)
        .overlay(Rectangle().fill(Tokens.sep).frame(height: 0.5), alignment: .top)
        .overlay(Rectangle().fill(Tokens.sep).frame(height: 0.5), alignment: .bottom)
    }
}

/// One reading region: a reader-label row, the big sentence (in that
/// reader's language, once one exists), and a smaller supplementary line.
/// Vertically centers a short sentence and lets a long one scroll to its
/// end, per HANDOFF section 3 - `minHeight` on the content, not the
/// `ScrollView` itself, is what lets a tall sentence grow past the
/// viewport instead of being clipped to it.
private struct FacingPane: View {
    let content: FacingPaneContent
    let identifierPrefix: String

    @ScaledMetric(relativeTo: .body) private var readerLabelSize: CGFloat = 13
    @ScaledMetric(relativeTo: .body) private var bigSize: CGFloat = 30
    @ScaledMetric(relativeTo: .body) private var smallSize: CGFloat = 15

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(content.readerLabel)
                            .font(.system(size: readerLabelSize, weight: .semibold))
                            .foregroundStyle(Tokens.text3)
                            .textCase(.uppercase)
                        if content.hasSegment {
                            speakerLabel
                        }
                        if content.isPartial {
                            HStack(spacing: 5) {
                                PulsingDot(color: Tokens.accent)
                                Text("Đang nhận dạng")
                            }
                            .font(.system(size: readerLabelSize, weight: .semibold))
                            .foregroundStyle(Tokens.accent)
                        }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("\(identifierPrefix)ReaderLabel")

                    if let big = content.big {
                        Text(big)
                            .font(.system(size: bigSize, weight: .semibold))
                            .foregroundStyle(Tokens.text)
                            .accessibilityIdentifier("\(identifierPrefix)Big")
                    } else if content.isTranslatingBig {
                        TranslatingPlaceholder(fontSize: smallSize)
                    }

                    if let small = content.small {
                        Text(small)
                            .font(.system(size: smallSize))
                            .foregroundStyle(Tokens.text2)
                    }
                }
                // `.leading`: horizontal leading, vertical CENTER - a short
                // sentence centers in the pane; a taller one grows past
                // `geo.size.height` and the ScrollView takes over.
                .frame(maxWidth: .infinity, minHeight: geo.size.height, alignment: .leading)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
            }
        }
    }

    private var speakerLabel: some View {
        Text(content.speakerText)
            .foregroundStyle(speakerColor)
    }

    private var speakerColor: Color {
        switch content.speakerColorRole {
        case .speakerA: return Tokens.speakerA
        case .speakerB: return Tokens.speakerB
        case .other: return Tokens.text2
        case .unidentified: return Tokens.text3
        }
    }
}
