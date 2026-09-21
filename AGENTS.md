# sermiva - a live conversation translator for iPhone

A native SwiftUI iPhone app: microphone capture, Soniox streaming transcription, translation, and
speaker labels on one conversation screen. This repository holds an approved design, an interactive
HTML prototype, and a hand-made Xcode project (`Sermiva.xcodeproj`) that currently covers only the
offline demo slice described in the Verify section below - the real Soniox integration is not
built yet.

`design/claude-handoff/HANDOFF.md` is the authority on screens, the session state machine, design
tokens, and the acceptance criteria. The design is settled; do not redesign it and do not reopen it
in passing. Inside it, `[mô phỏng]` marks prototype-only behaviour and `[thật]` marks behaviour that
must still be implemented and proven against the real service. Where that document and this one
disagree, the handoff wins on what the app is, and this file wins on how work is proven.

## Verify before handing back

Never report something as working without running it. If a step was skipped, say which one and why,
and paste the real output rather than describing it.

The project is `Sermiva.xcodeproj` (hand-written `project.pbxproj`, no project generator), scheme
`Sermiva` (a hand-written shared scheme committed at
`Sermiva.xcodeproj/xcshareddata/xcschemes/Sermiva.xcscheme` - do not delete it: without a committed
scheme, `xcodebuild` auto-generates one with parallel testing enabled, which runs tests on an
ephemeral cloned Simulator instead of the named one below), targets `Sermiva` (app), `SermivaTests`
(XCTest) and `SermivaUITests` (one XCUITest smoke test). Deployment target iOS 17.0. Bundle id
`com.clongnguyen6.sermiva` (`.SermivaTests` / `.SermivaUITests` for the test targets). These are the
commands that were actually run against the same Simulator - iPhone 17, UDID
`2D7326E3-8BFB-482C-ADB5-A449BD3E0CFD` - and actually passed; run them again from the repo root
before trusting a "compiles", "runs" or "behaves" claim. None of this runs automatically - there is
no CI and no pre-commit hook wired to any of it - so run it by hand every time:

```
xcodebuild -project Sermiva.xcodeproj -scheme Sermiva -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

xcodebuild -project Sermiva.xcodeproj -scheme Sermiva -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SermivaTests test

xcodebuild -project Sermiva.xcodeproj -scheme Sermiva -sdk iphonesimulator \
  -destination 'platform=iOS Simulator,name=iPhone 17' -only-testing:SermivaUITests test
```

The committed shared scheme sets `parallelizable = "NO"` on both test targets, which is what keeps
the two test commands on the named Simulator instead of a clone. To confirm a given run actually used
it: `xcrun simctl list devices` (the default device set) never shows parallel-testing clones - they
live in a separate set (`xcrun simctl --set testing list devices`) - so check the run's own
`.xcresult` bundle instead (path printed after "Test session results, code coverage, and logs:" in
the `xcodebuild` output): `xcrun xcresulttool get test-results tests --path <bundle>` and read
`deviceName`/`deviceId` under `devices` - it must match the named Simulator above, not a
`Clone N of iPhone 17`.

`build` proves "compiles". The `SermivaTests` run (state machine + segment assembly fixtures read
from `demo-data.json`) proves "behaves" for what those fixtures cover - nothing more; it also
launches `Sermiva.app` as its `TEST_HOST` process, which implies the app launched without crashing,
but that is a side effect of how `XCTest` hosts unit tests, not UI automation - nothing in it drives
the UI or looks at a screen.

The `SermivaUITests` run is the one thing that does drive the UI: it taps into the real committed
app (Setup -> demo -> Bat dau -> first fixture segment's real content visible, then a later segment's
content visible) with no hooks or shortcuts in product code, only accessibility identifiers. Passing
is real "runs" evidence, repeatable, not a one-off screenshot, with the demo's actual content attached
as screenshots in the test's result bundle. It proves only that one path - it says nothing about any
other display style, about Settings, or about anything needing Soniox.

A plain "install and observe" pass (`xcrun simctl install` / `launch` / `io screenshot`, no taps) is
weaker evidence than `SermivaUITests` - it cannot get past the Setup screen without tapping - but it
still proves the app installs and launches, and is a fallback if `SermivaUITests` cannot run for some
other reason.

Nothing here reaches "works live" - that rung needs a real Soniox key on a real device, per
Outcome 2.

State which rung your claim is on, every time:

| Claim | What proves it |
|---|---|
| compiles | build output |
| runs | launched on a named Simulator, and what you observed |
| behaves | a fixture-driven test over state and segment handling |
| works live | a real key on a real device, named, and what you heard |

A Simulator has no acoustic path, so echo, barge-in and the loudspeaker case are invisible there
while everything looks correct. Demo mode passing is evidence about demo mode. Overlapping speech,
per-segment language ID, `me`/`guest`/`target` routing and echo suppression are marked `[thật]` in
the handoff: never describe any of them as verified without hardware and a real key.

What is testable now and what is not. The session state machine (`HANDOFF.md` §5) and the segment
assembly rules (§6) are our own contract and already settled, so cover them with fixtures drawn from
`demo-data.json`. The shape of Soniox's own stream is not ours and is not yet known, so keep it
behind a thin adapter and do not write tests through that boundary. A test written around a contract
nobody has confirmed forces a compatibility layer that never goes away.

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
- Add anything the approved design does not describe: an account system, a subscription
  system, or a new feature.
- Open a streaming session against the real Soniox service. It is metered and costs money per
  session, including during a test run. Live testing happens when the owner asks for it, with a key
  the owner enters through the app's own screen.
- Add a dependency, or introduce a package manager or a project generator.
- Signing, device provisioning, TestFlight, or publishing anything.

## Scope discipline

Make the smallest change that solves the task as asked, and preserve the approved UI. Do not
refactor unrelated modules, rename types, or reformat large files unless explicitly asked. If you
see a wider cleanup worth doing, name it as follow-up work instead of doing it.

## Product invariants

Each of these corrects something the prototype or the handoff would otherwise lead you into.

- **Record the Soniox routing strategy before writing the integration.** Read the current official
  documentation first; the handoff predates it. `me`, `guest` and `target` are three independent
  settings, and one two-way translation configuration does not necessarily serve asymmetric targets.
  Write down what you chose and its limits. Every screen reads segments, so changing this later
  touches all of them.
- **Never infer speaker identity from language.** "Bạn" and "Khách" are configuration labels;
  A / B / "Chưa xác định" always come from diarization. A segment with no speaker stays
  unidentified rather than being assigned one.
- **A verified signal, or no badge.** Diarization is not an overlap detector. Do not render the
  "Nói chồng" state without a signal from the service that says so.
- **Microphone, network, transcription, translation and playback are five separate states.** Never
  show "Đang nghe" while capture is stopped. The prototype collapses these; the app must not.
- **Keys never appear in chat, in a log, in a URL, or in this repository.** Entry happens through
  the app's own screen into Keychain. The handoff's key pattern and its `sx_demo_...` value are
  `[mô phỏng]`; validate real credentials against the actual service.
- **Do not discard captured audio during playback as a shortcut for echo suppression.** Evaluate
  what the device actually supports, and write down the listening and playback tradeoff instead of
  hiding it.
- **Demo and live stay visibly separated.** Demo mode works with no credentials and must never be
  mistaken for a live session, in the interface or in a report.
- **Use real safe-area insets and Dynamic Type.** The prototype's fixed device measurements are a
  prototype artifact, and the app's own font-size setting is a separate axis from system Dynamic
  Type. Interface chrome still has to scale for accessibility.

## Tool-specific context

Claude Code reads `CLAUDE.md`, which imports this file.

## Maintenance

Update this file when any of these change: how a change is verified, the project or package layout,
the Soniox integration contract, or the release process. The Verify section above must keep matching
the actual scheme, targets and commands as the project grows past the offline demo slice.
