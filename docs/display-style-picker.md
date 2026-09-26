# Decision: the style-picker sheet shows two cards, not five

HANDOFF.md section 3 defines five display styles and section 3's own closing line: "Sheet
chọn kiểu: 5 thẻ xem trước dạng lưới 2 cột". Only two styles exist in the app yet - Phụ đề
(already shipped) and Đối diện (this outcome). Bong bóng, Sân khấu, Kịch bản are out of this
outcome's scope and do not exist as code.

`DisplayStylePickerSheet` reads `DisplayStyle.allCases` directly, so it shows exactly the
styles that exist - two cards today, growing to five automatically as the other three are
implemented, with no second list to keep in sync. The 2-column grid, the per-card mini
preview, and the selected card's `accent` border + checkmark are all unchanged from the
5-card design; only the card count is temporarily smaller. This is a deviation from the
letter of section 3, not from its intent, and needs no further approval to grow back to five
as the remaining styles ship.

# Decision: what each Đối diện region shows when no correct-language text exists

HANDOFF.md section 3 describes Đối diện as showing "câu mới nhất bằng ngôn ngữ của người đọc
bên đó" - the latest sentence in each reader's own language. The app's actual translation
routing (docs/soniox-routing.md) only ever produces ONE destination for a given segment's
`target` field: `target` (`en`) when the segment's language is `me` (`vi`), or `me` (`vi`)
for every other segment, regardless of what that other language actually is. A three-language
conversation (`me`, `target`, and a guest speaking neither) or a language not yet identified
by diarization therefore has no correct-language translation for one of the two regions - not
"not yet", but never, for that segment.

Owner's ruling, binding: a region's big line only ever holds text confirmed to be in that
region's own reader's language; if none exists, the big line stays empty rather than showing
text in some other language. The segment's own real source text always goes in the small line
instead when the big line is empty this way - never invented, and never the big line, since it
is not confirmed to be in this reader's language either. The me/Vietnamese reader's side of
both affected cases is explicitly unchanged by this ruling (kept as the source text on the big
line, small line empty) - only the target/English reader's side changes. `FacingPaneContent.make`
(`Sermiva/FacingTranscriptView.swift`) resolves each case as follows:

| Segment's language vs. this reader | Big line | Small line | Spinner |
|---|---|---|---|
| Same as this reader | the segment's own source text | the segment's translation, once it exists | never |
| `me`, reader is `target` | the segment's `target`-language translation | the segment's source text | while genuinely translating (`SegmentDisplay.showsTranslatingPlaceholder`) |
| Anything else, reader is `me` | the segment's `me`-language translation | the segment's source text | while genuinely translating |
| Not yet identified, reader is `me` | the segment's own source text, untranslated | nothing | never |
| A third language, or not yet identified, reader is `target` | empty - no text is confirmed to be in English | the segment's own source text, untranslated | never - no translation into this reader's language is ever requested for this segment |
| `me`, translation permanently unavailable (`targetAbandoned`), reader is `target` | empty - no text is confirmed to be in English, and none ever will be | the segment's own source text, untranslated | never |
| Anything else, translation permanently unavailable (`targetAbandoned`), reader is `me` | the segment's own source text, untranslated | nothing | never |

# Note: Facing's own icon buttons are explicitly sized, unlike the rest of the dock

`FacingTranscriptView`'s "Đổi bên" and ✕ icons carry an explicit `.font(.system(size:))` -
20 pt and 18 pt, the prototype's own SVG sizes - instead of the ambient default the rest of
the app's icon-only round buttons rely on (`ConversationView`'s Settings gear,
`LabeledRoundButton`'s Aa/Hiển thị icons). At the maximum accessibility text size, an
unspecified `Image(systemName:)` in a fixed 44 pt circle grows past that circle and clips
into an unreadable glyph for a two-stroke symbol like `arrow.up.arrow.down`, verified
side-by-side against the existing dock (whose own icons stayed legible at the same setting -
apparently tolerant of this for its own, simpler glyphs). Fixing this one spot was in scope
since it was a genuine visual break found while testing this outcome's own new buttons;
auditing every existing icon button against the same extreme setting is follow-up work, named
here rather than done, per scope discipline.

# Correction: landscape renders correctly - only `app.screenshot()` was wrong

An earlier version of this note claimed a Simulator/Xcode rendering limitation made landscape
unreachable. That was wrong, and the owner correctly rejected it as an unverified hypothesis.
The actual finding, pinned down by trying a screenshot path that does not go through XCUITest
at all:

- `app.screenshot()` (`XCUIScreenshot`, taken from the test process) reliably renders rotated
  content as a portrait-sized, 90°-rotated block pinned to one corner of the landscape canvas,
  the rest black - reproduced on `SetupView` too, a screen this outcome never touched, so it is
  specific to that API in this environment (Xcode 27 / iOS 26.5), not to this feature.
- `xcrun simctl io <UDID> screenshot` - the actual CoreSimulator framebuffer, captured
  independently of XCUITest - renders the exact same running app, in the exact same rotated
  state, correctly: full-width landscape, the top pane genuinely upside-down, the middle strip
  never overlapped. This environment has no `Simulator.app` GUI bundle installed (only the
  `simctl`/`xcodebuild` command-line tooling and the CoreSimulator daemon), so `Device > Rotate`
  via the Simulator app's own menu was not available to cross-check further, but the framebuffer
  result already settles which side owns the earlier bug.
- `XCUIElement.frame` (the accessibility geometry XCUITest itself reports, independent of the
  `app.screenshot()` bug above) matches the framebuffer capture exactly: measured with
  `SermivaUITests.test_facingLandscapeRegionsRespectInsetsWithNoOverlap`, each region's edge
  exactly meets the next with zero gap or overlap, all in landscape, all numerically, independent
  of any screenshot mechanism. (The exact top/bottom/leading/trailing numbers that test checks
  against changed after the real-safe-area fix below - see that section for the actual measured
  values.)

Screenshots for the handback were captured via `xcrun simctl io <UDID> screenshot` instead of
the UI test's own `app.screenshot()` for this reason.

# Ruling: real safe-area insets, not HANDOFF's prototype measurement alone

Looking at `facing-long-landscape.png` above (before this fix) showed "ĐỌC TIẾNG VIỆT" and the
mic dot sitting under iPhone 17's Dynamic Island / rounded corner in landscape - HANDOFF's
54/22/34 pt numbers come from the prototype's own fixed device frame, not this device's real
safe area, and AGENTS.md requires the real one. Owner's ruling, binding for this outcome: on the
non-rotated wrapper, each edge's inset is `max(HANDOFF's number for that edge, the device's real
safe-area inset for that edge)`; leading/trailing, which HANDOFF gives no number for, use the
real inset directly. Applies to both reading regions and the middle strip (whose background may
still run edge to edge; only its controls and text follow the inset).

`FacingTranscriptView.windowSafeAreaInsets` reads this from the key window directly
(`UIApplication.shared...windows.first(where: \.isKeyWindow)?.safeAreaInsets`), not through
`GeometryReader`'s own `safeAreaInsets` - confirmed empirically that the latter reports all
zeros here, because `ConversationView`'s own safe-area-respecting `VStack` (the parent this view
sits inside) has already excluded the safe area from what it offers this view before this view's
own `.ignoresSafeArea()` ever runs.

Measured once via that same read, on the pinned iPhone 17 Simulator (AGENTS.md's UDID):

| Orientation | Real top | Real bottom | Real leading | Real trailing | Applied top | Applied bottom | Applied leading | Applied trailing |
|---|---|---|---|---|---|---|---|---|
| Portrait | 62 | 34 | 0 | 0 | max(54,62)=**62** | max(34,34)=**34** | 0 | 0 |
| Landscape (either direction) | 0 | 20 | 62 | 62 | max(54,0)=**54** | max(22,20)=**22** | **62** | **62** |

Landscape reports the Island's clearance symmetrically on both the leading and trailing edge
regardless of which physical side it is actually on (Apple's own convention for Dynamic Island
devices) - confirmed by measuring both `landscapeLeft` and `landscapeRight` and finding identical
numbers, which is also why the screenshots below look the same in both rotation directions.
Portrait's real top (62) exceeds HANDOFF's 54, which is exactly the case AGENTS.md's rule exists
for: a long upside-down sentence scrolling in the top pane clips to this pane's own `ScrollView`
bounds, which start at the applied (62, not 54) inset - confirmed both by the numeric UI test and
by looking at `facing-long-portrait.png`'s top edge directly.
