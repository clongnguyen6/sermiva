import SwiftUI
import UIKit

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
                // `segment.targetAbandoned`: the translation is permanently
                // unavailable, not merely pending - per
                // docs/display-style-picker.md's ruling, the big line falls
                // back to the segment's own untranslated source text rather
                // than staying blank, with no supplementary line (the only
                // other field, `sourceText`, is already the big line here).
                if segment.targetAbandoned {
                    return FacingPaneContent(readerLabel: readerLabel, hasSegment: true, speakerText: speakerText, speakerColorRole: speakerColorRole, isPartial: isPartial, big: latest.sourceText, isTranslatingBig: false, small: nil)
                }
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
    /// AGENTS.md: "Demo and live stay visibly separated." Facing hides
    /// `ConversationView`'s own top bar - the only other place the `DEMO`
    /// badge lives - so the middle strip shows it here instead while this
    /// is true.
    let isDemo: Bool
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

    /// The real device safe area, read straight from the key window rather
    /// than through `GeometryReader`'s own `safeAreaInsets` - by the time
    /// this view's `.ignoresSafeArea()` (below) takes effect, a `GeometryReader`
    /// nested inside it reports all zeros here (confirmed empirically: this
    /// view sits inside `ConversationView`'s own safe-area-respecting
    /// `VStack`, which has already excluded the safe area from what it
    /// offers this view before `.ignoresSafeArea()` ever runs). HANDOFF's
    /// 54/22/34 pt numbers are a prototype measurement, not a real device's
    /// own insets (AGENTS.md's real-safe-area-insets rule) - see
    /// docs/display-style-picker.md for the owner's ruling combining them.
    private var windowSafeAreaInsets: UIEdgeInsets {
        UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first(where: \.isKeyWindow) }
            .first?.safeAreaInsets ?? .zero
    }

    var body: some View {
        GeometryReader { geo in
            // Owner's ruling (docs/display-style-picker.md): on this
            // non-rotated wrapper, each edge's inset is
            // max(HANDOFF's number for that edge, the device's real safe
            // area for that edge). HANDOFF gives no number for leading/
            // trailing, so those use the real inset directly. Applies to
            // both reading regions and the middle strip.
            let isLandscape = geo.size.width > geo.size.height
            let safe = windowSafeAreaInsets
            let topInset = max(54, safe.top)
            let bottomInset = max(isLandscape ? 22 : 34, safe.bottom)
            VStack(spacing: 0) {
                // The identifier lands on `FacingPane`'s own `ScrollView` -
                // exactly the padding-constrained region a long sentence
                // scrolls within, which is what SermivaUITests asserts the
                // exact insets and the no-overlap boundaries against
                // (`facingTopWrapper`/`facingBottomWrapper`).
                FacingPane(content: topContent, identifierPrefix: "facingTop")
                    .rotationEffect(.degrees(180))
                    .padding(.top, topInset)
                    .padding(.leading, safe.left)
                    .padding(.trailing, safe.right)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("facingTopWrapper")

                middleStrip(leadingInset: safe.left, trailingInset: safe.right)

                FacingPane(content: bottomContent, identifierPrefix: "facingBottom")
                    .padding(.bottom, bottomInset)
                    .padding(.leading, safe.left)
                    .padding(.trailing, safe.right)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("facingBottomWrapper")
            }
        }
        .ignoresSafeArea()
        .background(Tokens.bg)
    }

    @ScaledMetric(relativeTo: .body) private var micTextSize: CGFloat = 12
    @ScaledMetric(relativeTo: .body) private var stripLabelSize: CGFloat = 14

    private var showsPauseIcon: Bool { primaryLabel == "Tạm dừng" }

    /// Mic dot/icon/status text (and, in demo, the `DEMO` badge - see
    /// `isDemo`): the strip's one flexible-width element. No `lineLimit` -
    /// review round 3, finding 2: at the largest accessibility text size
    /// this used to hard-truncate to "Mic…" instead of wrapping, the one
    /// state text in the strip that must never be unreadable. No `lineLimit`
    /// is also what makes `ViewThatFits` (below) measure this row's real,
    /// unwrapped width when deciding whether the one-row layout still fits -
    /// wrapping to more lines in the stacked layout instead is what "the
    /// strip may grow in height if needed" (same finding) is for.
    private var micStatusRow: some View {
        HStack(spacing: 6) {
            if isDemo {
                DemoBadge()
            }
            Circle().fill(micDotColor).frame(width: 8, height: 8)
            Image(systemName: micIconName)
                .font(.system(size: micTextSize))
                .foregroundStyle(Tokens.text2)
                .accessibilityHidden(true)
            Text(micDockText)
                .font(.system(size: micTextSize, weight: .semibold))
                .foregroundStyle(Tokens.text2)
        }
        .frame(minHeight: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Tạm dừng/Tiếp tục · Đổi bên · ✕ - grouped so the accessibility-size
    /// layout below can give this its own row, separate from `micStatusRow`.
    private var controlsRow: some View {
        HStack(spacing: 6) {
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
    }

    private func middleStrip(leadingInset: CGFloat, trailingInset: CGFloat) -> some View {
        // Review round 4: picking the layout off `isDemo` or an
        // accessibility-size flag was itself the bug - at DEFAULT text size
        // with `isDemo` true it forced two rows even in landscape, where one
        // row has ~870 pt to work with and uses under half of it, costing
        // the two reading regions real height for no reason. `ViewThatFits`
        // instead measures each candidate's own real (unwrapped, since
        // neither row's `Text` sets `lineLimit`) width against what the
        // strip actually has, so the same one-row-if-it-fits rule holds for
        // any text size, orientation, and DEMO badge state, not just the
        // ones this review happened to check.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                micStatusRow
                controlsRow
            }
            // Stacked fallback, once the row above genuinely does not fit.
            // `controlsRow` is trailing-aligned here - in the one-row
            // layout above, `micStatusRow`'s own `.frame(maxWidth: .infinity)`
            // already pushes `controlsRow` to the strip's trailing edge, so
            // anchoring it there again (instead of leaving it left-aligned
            // with a large empty band beside it) keeps the two layouts
            // looking like the same design at two heights, not two designs.
            VStack(alignment: .leading, spacing: 8) {
                micStatusRow
                controlsRow
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        // The strip's own 10 pt is design breathing room, not a safe-area
        // clearance claim (unlike the panes' 54/22/34, it never stood in
        // for the real inset) - so the real safe area (e.g. the Dynamic
        // Island's landscape side clearance) stacks additively on top of
        // it here, the same additive relationship the panes have between
        // their wrapper's own safe-area padding and `FacingPane`'s internal
        // 22 pt content padding. `.background` below applies to this same
        // (now wider-padded) row, which still spans the full width offered
        // to it: the flexible mic-status row above absorbs the extra
        // padding, so the row's own total width - and therefore its
        // background - never shrinks in from the true screen edge.
        .padding(.leading, 10 + leadingInset)
        .padding(.trailing, 10 + trailingInset)
        .padding(.vertical, 6)
        .background(Tokens.surface)
        .overlay(Rectangle().fill(Tokens.sep).frame(height: 0.5), alignment: .top)
        .overlay(Rectangle().fill(Tokens.sep).frame(height: 0.5), alignment: .bottom)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("facingMiddleStrip")
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
