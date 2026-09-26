# sermiva - a live conversation translator for iPhone

A native SwiftUI iPhone app: microphone capture, Soniox streaming transcription, translation, and
speaker labels on one conversation screen. This repository holds an approved design, an interactive
HTML prototype, and a hand-made Xcode project (`Sermiva.xcodeproj`) with two slices: an offline demo
(no network, no real mic) and a live Soniox session, both covered in the Verify section below.

`design/claude-handoff/HANDOFF.md` is the authority on screens, the session state machine, design
tokens, and the acceptance criteria. The design is settled; do not redesign it and do not reopen it
in passing. Inside it, `[mô phỏng]` marks prototype-only behaviour and `[thật]` marks behaviour that
must still be implemented and proven against the real service. Where that document and this one
disagree, the handoff wins on what the app is, and this file wins on how work is proven.

## Verify before handing back

Never report something as working without running it; paste real output, not a description. If a
step was skipped, say which one and why. Nothing runs automatically; run it by hand every time:
```
./scripts/verify.sh
```

Boots iPhone 17 by UDID (`2D7326E3-8BFB-482C-ADB5-A449BD3E0CFD`), not name, from repo root; builds
and tests on the Simulator only. Exit is non-zero for: build failure, test failure, a clone
signature, the Simulator stuck "Shutting Down", or UDID missing/not Booted (not asserted a clone).
`--device` additionally builds and installs (never launches) on the owner's iPhone "Long" by UDID
(`00008101-000138D801F8001E`), under development signing. State which rung your claim is on, every
time:

| Claim | What proves it |
|---|---|
| compiles | the `build` step |
| runs | `SermivaUITests`: the real committed app, no product-code hooks, only accessibility identifiers; checks the first and a later fixture segment in Phụ đề; enters Đối diện through the "Hiển thị" sheet, checks the top region renders rotated 180°, and confirms ✕ returns to Phụ đề with the session's paused state and transcript intact; separately rotates to landscape and numerically checks both Đối diện regions and the middle strip against the exact 54/22 pt insets with zero gap or overlap (`app.screenshot()` itself renders landscape content incorrectly in this environment - `XCUIElement.frame` does not; see docs/display-style-picker.md); its screenshots land in the test's result bundle |
| behaves | `SermivaTests`: state machine, segment assembly, the connection lifecycle (a seeded invariant fuzz over fake sockets and a virtual clock; `TEST_RUNNER_SERMIVA_FUZZ_SEEDS` in xcodebuild's environment scales it, not as an argument), the on-device translation queue (through a fake, never real Apple Translation), Keychain, and Đối diện's per-region text selection (`FacingTranscriptViewTests`) - nothing beyond what those cover; it launches the app as its `TEST_HOST`, which is not UI automation - nothing in it drives or looks at the UI |
| works live | a real Soniox key on a real device, named, and what you heard - never proven by this script; the owner runs that session; Apple Translation never runs in the Simulator either, so it too can only ever reach this rung |

This does not cover Settings, the three display styles that do not exist yet (Bong bóng, Sân
khấu, Kịch bản), per-segment language ID, `me`/`guest`/`target` routing, or real audio hardware
(echo, barge-in, overlapping speech, loudspeaker case) - all `[thật]` in the handoff, and unit
tests of app-owned logic do not prove what the real service does.
On the Simulator these also look indistinguishable from correct, since nothing here exercises real
hardware. Soniox's stream shape is untested behind a thin adapter, so do not write tests through it -
a test around an unconfirmed contract forces a compatibility layer that never goes away.

Do not delete the committed scheme at `Sermiva.xcodeproj/xcshareddata/xcschemes/Sermiva.xcscheme`:
its `parallelizable = "NO"` keeps runs on the named device; without it, `xcodebuild` auto-generates
a parallel scheme that silently moves tests onto a clone, which `scripts/verify.sh` checks for.

## Source of truth

`design/claude-handoff/` is an approved handoff package, and reference material rather than
application code.

- `HANDOFF.md` and `demo-data.json` are authoritative. `demo-data.json` is the fixture that offline
  demo mode plays back, and the fixture the tests above read.
- `Sermiva.dc.html`, `Sermiva.standalone.html`, `ios-frame.jsx`, `support.js` are the prototype and
  its runtime. `HANDOFF.md` §13 states they are not used by the app.

Never edit anything under `design/claude-handoff/`, and never ship the prototype HTML inside a
WebView. Rebuild the interface in SwiftUI.

## Do not do without asking first

- Change an approved screen, flow, token, or acceptance criterion.
- Add anything the approved design does not describe: accounts, subscriptions, or a new feature.
- Open a streaming session against the real Soniox service. It is metered and costs money per
  session, including during a test run. Live testing happens when the owner asks, with a key the
  owner enters through the app's own screen.
- Add a dependency, or introduce a package manager or a project generator.
- TestFlight, App Store Connect, distribution certificates, or publishing anything. Development
  signing under the owner's personal team, to install on the owner's device (Verify's `--device`
  flag), is approved; an Apple account in Xcode, Developer Mode, and trusting the Mac stay the
  owner's own steps.
- Change anything outside this repository: system settings, security or privacy configuration,
  machine-wide tool configuration, or another project. The one exception is the Simulator itself -
  any operation on it (creating, booting, shutting down, erasing, deleting, changing settings,
  restarting its service) is routine. Installing, deleting, or downloading a Simulator runtime or an
  Xcode platform (`xcrun simctl runtime`, `xcodebuild -downloadPlatform`) is not part of that
  exception - it reaches outside this Simulator instance, so ask first.

## Scope discipline

Make the smallest change that solves the task as asked, and preserve the approved UI. Do not
refactor unrelated modules, rename types, or reformat large files unless explicitly asked. If you
see a wider cleanup worth doing, name it as follow-up work instead of doing it.

## Product invariants

Each of these corrects something the prototype or the handoff would otherwise lead you into.

- **Record the Soniox routing strategy before writing the integration.** Read current official docs
  first, not the handoff. `me`, `guest`, `target` are independent settings; one two-way config does
  not necessarily serve asymmetric targets. Write down what you chose and its limits - every screen
  reads segments, so changing this later touches all. Decided; see docs/soniox-routing.md.
- **Never infer speaker identity from language.** "Bạn" and "Khách" are configuration labels;
  A / B / "Chưa xác định" always come from diarization. A segment with no speaker stays
  unidentified rather than being assigned one.
- **A verified signal, or no badge.** Diarization is not an overlap detector. Do not render the
  "Nói chồng" state without a signal from the service that says so.
- **An activity indicator only shows while that activity is genuinely running.** Microphone,
  network, transcription, translation and playback are five separate states, each with its own
  label ("Đang nghe", "Đang nhận dạng", "Đang dịch…"), spinner, pulsing dot, or caret; none of them
  may reflect a segment's own stale shape or another activity's state once the real one has stopped.
  When it stops, hide the indicator or fall back to an existing true state - never write new copy.
  The prototype collapses these; the app must not.
- **Keys never appear in chat, in a log, in a URL, or in this repository.** Entry happens through
  the app's own screen into Keychain. The handoff's key pattern and its `sx_demo_...` value are
  `[mô phỏng]`; validate real credentials against the actual service.
- **Do not discard captured audio during playback as a shortcut for echo suppression.** Evaluate
  what the device actually supports, and write down the listening/playback tradeoff instead of
  hiding it.
- **Demo and live stay visibly separated.** Demo mode works with no credentials and must never be
  mistaken for a live session, in the interface or in a report.
- **Use real safe-area insets and Dynamic Type.** The prototype's fixed measurements are a prototype
  artifact; the app's own font-size setting is a separate axis from system Dynamic Type. Interface
  chrome still has to scale for accessibility.

## Maintenance

Claude Code reads `CLAUDE.md`, which imports this file. Update it when any of these change: how a
change is verified, the project or package layout, the Soniox integration contract, or the release
process. Verify above must keep matching the scheme, targets and commands over time.
