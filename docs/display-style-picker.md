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
"not yet", but never, for that segment. AGENTS.md forbids inventing text and this outcome's
own instructions forbid an extra translation call, so `FacingPaneContent.make`
(`Sermiva/FacingTranscriptView.swift`) resolves each of the six cases as follows - owner
review of this table stands in for a design change, since HANDOFF's own text does not cover
a three-language guest:

| Segment's language vs. this reader | Big line | Small line | Spinner |
|---|---|---|---|
| Same as this reader | the segment's own source text | the segment's translation, once it exists | never |
| `me`, reader is `target` | the segment's `target`-language translation | the segment's source text | while genuinely translating (`SegmentDisplay.showsTranslatingPlaceholder`) |
| Anything else, reader is `me` | the segment's `me`-language translation | the segment's source text | while genuinely translating |
| Anything else, reader is `target` (a third language, or not yet identified) | the segment's own source text, untranslated | nothing | never - no translation into this reader's language is ever requested for this segment |
| `me`, translation permanently unavailable (`targetAbandoned`) | the segment's own source text, untranslated | nothing | never |

The last two rows both fall back to the segment's real, un-invented source text rather than
leaving the big line blank or reusing the other language's `target` field mislabeled as this
reader's own. This is a judgment call on the app's part, not a described design behaviour -
flagged here for the project owner to confirm or override.

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
  `SermivaUITests.test_facingLandscapeRegionsRespectInsetsWithNoOverlap`, the top pane starts
  54 pt below the true top edge, the bottom pane ends 22 pt above the true bottom edge (not
  portrait's 34 pt), and each region's edge exactly meets the next with zero gap or overlap -
  all in landscape, all numerically, independent of any screenshot mechanism.

Screenshots for the handback were captured via `xcrun simctl io <UDID> screenshot` instead of
the UI test's own `app.screenshot()` for this reason.
