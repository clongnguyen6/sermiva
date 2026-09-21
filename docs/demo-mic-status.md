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
per AGENTS.md and the outcome brief. It also does not implement `reconnecting` or
`authError`: those states exist on `SessionState` for contract completeness but
nothing in this slice can produce the network/auth signal that would drive into them.
