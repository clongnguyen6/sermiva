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

## Decision

This slice requests the real system microphone permission at the real moment (the
first tap on "Bat dau"), and once granted, genuinely opens an `AVAudioEngine` input
tap for as long as the state is `listening`. The buffers are discarded immediately -
nothing is stored, sent anywhere, or run through recognition, since there is nothing
in this slice that could use them. Pausing or ending the session stops the tap and
deactivates the audio session, matching the "mic tat" line whenever capture is
genuinely stopped.

The same honesty requirement applies when capture stops for a reason outside the
user's own pause tap: backgrounding, an interruption (a call, Siri, another app
taking the mic), or a media services reset. `MicrophoneCapture` observes those three
signals directly and reports back through `onUnexpectedStop`; the controller treats
that exactly like an explicit pause (stop playback, `state = .paused`), so the dock
never keeps asserting "Dang nghe" once the OS has actually taken the mic away. This
also covers the concrete case of backgrounding: the app declares no
`UIBackgroundModes: audio` entitlement, so iOS silently kills the tap on its own the
moment the app leaves the foreground regardless of what the app does - reacting to
`didEnterBackgroundNotification` makes that visible immediately instead of leaving a
stale "listening" state until something else happens to notice. The controller also
stops capture in `deinit`, so the mic cannot stay open if the controller is ever
dropped from the view tree.

A capture failure (`engine.start()` throwing) is treated as a hardware/engine
problem, not a permission denial - reporting `micDenied` for it would tell the user
"you have not granted microphone access" when they actually have, which is worse
than saying nothing. HANDOFF.md section 5 has no dedicated mic-error state and the
approved design has no banner for one, so this slice does not invent either; it
returns to `idle` ("Mic tat") and leaves a real, named gap: **there is currently no
UI signal that distinguishes "never asked" from "asked and the engine failed to
open"; both look like idle.** That is a decision for the project owner to make in a
later outcome, not something to paper over here.

## Audio session category

`MicrophoneCapture` activates the session with category `.record`, not
`.playAndRecord`. This slice never plays any audio back (no TTS, no live segment
readback), so forcing an output route at all - to the speaker via `.defaultToSpeaker`,
or to a Bluetooth headset via `.allowBluetoothHFP` - would be asserting a playback
concern the app has no playback to justify. `.record` avoids both.

This does not make the demo session invisible to the rest of the system: activating
any non-ambient audio session, including a record-only one, still takes audio focus
and will interrupt another app's background playback for as long as the demo is
listening. That is an unavoidable consequence of requesting real microphone access at
all (true for essentially any voice app, live or demo), not something specific to how
this slice configured the session - the category choice only controls whether the
*output* route gets forced too, and here it does not.

Given that, the mic dock text stays keyed purely off `SessionState`, exactly like the
approved design: "Dang nghe" during `listening` is literally true, because the mic
really is capturing. The `DEMO` badge and the "Phien mo phong" connection-status line
are what tell the user this is not a live Soniox session - not a weaker or hedged mic
line. This also satisfies acceptance criterion 9 end to end without inventing
anything: the permission prompt fires at the real moment, and a denial produces a
genuine `micDenied` state with the real banner to iPhone Settings, not a simulated
one.

## Rejected alternative

Skip the real permission/capture in demo mode and either show a demo-only mic string
("Demo - khong mo mic") or silently leave the dock saying "Dang nghe" without ever
opening hardware. Both were rejected: the first invents UI copy the approved design
does not have and that HANDOFF.md section 5 does not list among the six sanctioned
mic-dock strings; the second is exactly the dishonest state AGENTS.md forbids - a
capture-state label asserting activity the app has no signal for. Requesting real
permission also happens to be the only way to exercise the `micDenied` branch and
prove criterion 9 without a live Soniox key, which this slice needs anyway.

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
interaction (no accessibility automation, no XCUITest target in scope), so the
external-stop path is proven by a unit test that calls the capture's own
`onUnexpectedStop` callback directly, plus reading `MicrophoneCapture`'s notification
registration and cleanup code - not by an observed Home-press on device.
