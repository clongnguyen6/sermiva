# Decision: what the mic dock says during demo playback, and whether demo opens the mic

## Question

AGENTS.md treats microphone, network, transcription, translation and playback as five
separate states and says "never show 'Dang nghe' while capture is stopped." Demo mode
plays back a canned fixture and recognizes nothing real. So while a demo session is
"listening," what does the mic status line on the dock say, and does the app actually
open the microphone hardware at all?

## What the approved design already decided

The approved prototype (`design/claude-handoff/Sermiva.standalone.html`, read-only,
not shipped) computes the mic dock label purely from session state, with no
demo-mode branch:

```
if (sess === 'listening') micKey = 'listening';
...
micLabel: t.mic[micKey]   // 'Dang nghe' when listening, regardless of demoMode
```

Demo separation happens on a different line: the connection-status text is replaced
with "Phien mo phong" ("Simulated session") while listening or paused, and the `DEMO`
badge is always visible. The mic line itself is never softened for demo. That is a
completed design decision, not something this outcome gets to redo - it only has to
be honored by something that is actually true.

The prototype's own model does not have a way to represent "session running, capture
failed": it is pure simulation with no real hardware to fail. This slice does have
that failure mode, for real (see "What actually happened in this Simulator" below),
so the mapping below extends the prototype's decision instead of copying it verbatim.

## Decision

`DemoSessionController` publishes `isMicCapturing` as its own value, separate from
`state`. It becomes `true` only right after `audioCapture.start()` genuinely succeeds,
and `false` the moment capture stops for any reason - an explicit pause, ending the
session, or capture stopping itself (see "External stops" below). Every mic-facing
piece of UI - the dock's mic line and the empty-state "Dang nghe..." with its red dot
- reads `isMicCapturing` directly, never `state`. HANDOFF.md section 5's six mic-dock
strings are chosen as: "Dang nghe" when `isMicCapturing` is true; otherwise the string
that matches *why* it is not - "Da tam dung" while paused, "Dang mo mic..." while
asking or connecting, "Chua co quyen mic" while denied - except while `state ==
.listening` itself, which falls back to "Mic tat": that is the one case where the
session is genuinely running but capture is not, and "Mic tat" is the only one of the
six strings that stays literally true then.

This slice still requests the real system microphone permission at the real moment
(the first tap on "Bat dau"), and on grant, genuinely attempts to open an
`AVAudioEngine` input tap. The buffers are discarded immediately - nothing is stored,
sent anywhere, or run through recognition, since there is nothing in this slice that
could use them.

**Playback of the fixture never depends on capture succeeding.** The session state
machine and the mic capture are separate states per AGENTS.md, and the first version
of this decision violated that by folding a capture failure into the session itself
(returning to `idle`), which meant the one concrete outcome this whole slice exists to
prove - open the app, start the demo, watch the sample conversation play - silently
failed to happen on any machine where the Simulator has no usable audio input. That
is now fixed: a failed `audioCapture.start()` still lets the session reach `listening`
and play the fixture normally; only `isMicCapturing` reports the truth (false), via
"Mic tat" on the dock. The gap named in the previous version of this file - no signal
distinguishing "never asked" from "asked and the engine failed" - still exists in
exactly that form ("Mic tat" covers both `idle` and a failed-but-listening session)
and is still the project owner's call to make in a later outcome.

## What actually happened in this Simulator

`engine.inputNode.outputFormat(forBus: 0)` returns a zero-channel format in this
sandboxed agent environment - there is no real microphone hardware wired to the
Simulator process here. Calling `installTapOnBus` with that format does not throw a
Swift error; it raises an Objective-C exception that `try`/`catch` cannot intercept,
which aborted the whole process (crash log
`Sermiva-2026-09-21-133029.ips`, `SIGABRT`, frame `MicrophoneCapture.start()`). `start()`
now checks `channelCount`/`sampleRate` before ever calling `installTapOnBus` and
throws a normal, catchable error instead. Whether a real developer machine (or a
different Simulator with host mic access) would ever exercise this path is unverified
from here; the guard is correct defensively either way, and the earlier crash is proof
this exact failure is real, not hypothetical.

## External stops

Capture also stops itself for a reason outside the user's own pause tap: backgrounding,
an interruption (a call, Siri, another app taking the mic), or a media services reset.
`MicrophoneCapture` observes those three signals directly and reports back through
`onUnexpectedStop`. The controller sets `isMicCapturing = false` immediately either way,
and additionally moves `state` to `paused` (mirroring an explicit pause, including
halting playback) rather than leaving the session "listening" with a dead mic and the
fixture silently continuing to advance while the app is not even in the foreground.
This is a judgment call, not the only reasonable one section 5 would support - written
down here per that requirement. The controller also stops capture in `deinit`, so the
mic cannot stay open if the controller is ever dropped from the view tree.

This also covers backgrounding concretely: the app declares no `UIBackgroundModes:
audio` entitlement, so iOS silently kills the tap on its own the moment the app leaves
the foreground regardless of what the app does - reacting to
`didEnterBackgroundNotification` makes that visible immediately instead of leaving a
stale state until something else happens to notice.

## Audio session category

`MicrophoneCapture` activates the session with category `.record`, not
`.playAndRecord`. This slice never plays any audio back (no TTS, no live segment
readback), so forcing an output route at all - to the speaker via `.defaultToSpeaker`,
or to a Bluetooth headset via `.allowBluetoothHFP` - would be asserting a playback
concern the app has no playback to justify. `.record` avoids both.

This does not make the demo session invisible to the rest of the system: activating
any non-ambient audio session, including a record-only one, still takes audio focus
and will interrupt another app's background playback for as long as capture is open.
That is an unavoidable consequence of requesting real microphone access at all (true
for essentially any voice app, live or demo), not something specific to how this
slice configured the session - the category choice only controls whether the
*output* route gets forced too, and here it does not.

## Rejected alternative

Skip the real permission/capture in demo mode and either show a demo-only mic string
("Demo - khong mo mic") or silently leave the dock saying "Dang nghe" without ever
opening hardware. Both were rejected: the first invents UI copy the approved design
does not have and that HANDOFF.md section 5 does not list among the six sanctioned
mic-dock strings; the second is exactly the dishonest state AGENTS.md forbids - a
capture-state label asserting activity the app has no signal for. Requesting real
permission also happens to be the only way to exercise the `micDenied` branch and
prove criterion 9 without a live Soniox key, which this slice needs anyway.

Also rejected: keeping the first version's choice to fold a capture failure into
`state` (returning to `idle`). It reads as simpler - one state to watch instead of
two - but it is wrong on its own terms: it makes the demo's one required outcome
(play the sample conversation) depend on hardware this slice has no business
depending on, and AGENTS.md already settled that microphone and session are separate
states before this outcome started.

## Limits

This does not implement or test echo suppression, barge-in, or any interaction
between the open tap and eventual TTS playback - those stay `[that]` and out of scope
per AGENTS.md and the outcome brief. `reconnecting` and `authError` exist on
`SessionState` for contract completeness, and the primary-button and `canEnd`
mappings do handle `reconnecting` correctly (tested as a pure function of state), but
nothing in this slice can produce the network/auth signal that would actually drive
either state - no path in product code reaches them, and none was added just to make
them reachable for testing.

Not verified on a real Simulator in this outcome: an actual Home-button-and-return or
a real phone-call interruption. This environment has no way to drive Simulator UI
interaction (no accessibility automation, no XCUITest target committed to the repo),
so the external-stop path is proven by a unit test that calls the capture's own
`onUnexpectedStop` callback directly, plus reading `MicrophoneCapture`'s notification
registration and cleanup code - not by an observed Home-press on device.
