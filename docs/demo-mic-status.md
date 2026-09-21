# Decision: what the mic dock says during demo playback

## Current decision (project owner, supersedes the two below)

Demo does not open real microphone hardware and does not ask for the real OS
permission. It never had anything to feed a real capture to, and a genuinely open mic
would light the privacy indicator and make demo indistinguishable from a live
session - which is exactly what AGENTS.md's "Demo and live stay visibly separated"
forbids.

`DemoSessionController` still publishes `isMicCapturing`, separate from `state`
(kept from the previous decision below). In demo, it is always `false`: the
production wiring uses `AutoGrantedMicPermission` (resolves granted instantly, no
real system alert) and `NullAudioCapture` (`start()` always throws on purpose). The
state machine still passes through `requestingMic -> connecting -> listening`
exactly as designed - only the two dependencies behind it are inert. The dock is one
of the six HANDOFF.md section 5 strings, chosen by `DemoSessionController
.micDockText(isMicCapturing:state:)`: with `isMicCapturing` always false, `listening`
maps to "Mic tat", which is literally true - nothing is capturing. The empty-state
"Dang nghe..." with its red dot also reads `isMicCapturing`, so it never appears in
demo either.

The `micDenied` branch of the state machine is real and stays testable - via
`FakeMicPermissionProvider(granted: false)` in `SessionStateMachineTests` - but
nothing in the shipped demo path can reach it, since `AutoGrantedMicPermission`
never says no. The real permission prompt, the real `micDenied` branch a user can
actually hit, and the real audio capture backend all belong to Outcome 2.

`MicrophoneCapture` (real `AVAudioEngine`) and `SystemMicPermissionProvider` (real
`AVAudioApplication`) were removed rather than kept unused: neither could be
exercised by anything that runs today, and AVAudioSession code nobody can run is
exactly the kind of surface that should not sit in the tree waiting to be reviewed
against a contract nobody has proven. `NSMicrophoneUsageDescription` was removed
from the app's Info.plist settings for the same reason - nothing in this build asks
for microphone access. Outcome 2 reintroduces both, alongside the real Soniox
integration and routing decisions they exist to serve.

`AudioCapturing.onUnexpectedStop` and `DemoSessionController
.handleCaptureStoppedExternally` (falls back to `paused`, not a stale "listening")
are kept even though nothing in demo can trigger them - they are the seam Outcome
2's real capture backend needs, already tested against a fake. Same reasoning as
`SessionState.reconnecting`/`.authError`: contract kept, not reachable here, nothing
added just to make it reachable.

## Superseded: capture failure falls back to idle (first version)

The first version of this decision kept demo's mic permission and capture as real
API calls, and treated a capture failure as "return to idle." That broke on this
machine: the Simulator's audio input reports zero channels here, so capture always
failed, and folding that into `state` meant demo silently never played - the one
concrete outcome this whole slice exists to prove. Fixed by publishing
`isMicCapturing` separately so playback never depends on capture succeeding. Then
superseded entirely by the decision above, which stopped attempting real capture at
all.

That attempt did surface one real, permanent bug worth keeping regardless of the
mic decision: `engine.inputNode.outputFormat(forBus: 0)` returning a zero-channel
format made `installTapOnBus` raise an uncatchable Objective-C exception
(`SIGABRT`, crash log `Sermiva-2026-09-21-133029.ips`). Any future real capture
backend must check `channelCount`/`sampleRate` before calling `installTapOnBus`,
the same way the removed `MicrophoneCapture.start()` did.

## Superseded: mic dock keyed off session state (original)

The very first version kept the approved prototype's own choice - the mic dock
computed purely from `state`, with demo requesting real permission and capture like
a live session would. Superseded because it made demo indistinguishable from live
at the OS level (privacy indicator, audio focus), which the current decision above
exists to fix.
