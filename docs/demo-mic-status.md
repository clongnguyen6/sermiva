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
exactly as designed - only the two dependencies behind it are inert.

An earlier pass here relied on `isMicCapturing` being false to fall through the
six-string `state` switch to "Mic tat" for `listening` - but that switch also maps
`paused` to "Da tam dung", `requestingMic`/`connecting` to "Dang mo mic...", and so
on, all of which still claim a mic that is opening, held, or was open, even though
demo never opened one. The project owner's rule (see the string-audit addendum
below) is that no approved string may claim that in demo; `DemoSessionController
.micDockText(isMicCapturing:state:isDemo:)` now checks `isDemo` first and returns
"Mic tat" unconditionally before the state switch ever runs, for every session
state demo can pass through, not only `listening`. The six-string switch stays
underneath, reachable once `isDemo` is false, for Outcome 2's real session. The dot
color next to the dock (`ConversationView.micDotColor`) follows the same rule: in
demo it stays neutral in every state, never the "asking" amber or "live" green.

The empty-state "Dang nghe..." with its red dot reads `isMicCapturing`, so it never
appears in demo either - and, checked directly against `DemoSessionController`'s
synchronous call chain, it could not appear even transiently: `beginRequestingMic`
-> `AutoGrantedMicPermission.requestPermission`'s completion -> `beginConnecting`
-> `startCaptureAndPlayback` -> `playNextEvent` all run on the same call stack with
no dispatch hop in between, so `state` reaches `listening` and the first segment is
already applied before SwiftUI ever renders a frame in between. There is no frame
where demo is `listening` with zero segments for the empty-state's `isEmptyListening`
branch to ever be visible for.

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

## Addendum: string-by-string audit against `Sermiva.dc.html`'s `T` table

The project owner's rule: in demo, any approved string that claims the mic is
active, opening, or about to turn off must either drop that clause or be replaced
by an existing true state - no new copy, and stop and ask if a string cannot be
resolved either way. Checked every mic/listening-related entry in `T.vi`/`T.en`
(`Sermiva.dc.html`, the string tables) against what demo actually shows:

Changed:

| String (key) | Before | After (demo only) | Language | Location |
|---|---|---|---|---|
| `endBody` | "Mic sẽ tắt. Bản ghi vẫn xem lại được cho đến khi bạn bắt đầu phiên mới." | "Bản ghi vẫn xem lại được cho đến khi bạn bắt đầu phiên mới." | vi | `EndSessionSheet.bodyText(isDemo:)` |
| `endBody` (en, not implemented in app) | "The mic will turn off. The transcript stays readable until you start a new session." | same drop, once English localization exists | en | n/a - app has no English strings; noted for when localization is added |

Checked, not changed - already resolved structurally, no code change needed:

- `mic.off` ("Mic tắt"): already the true state; this is what demo now shows unconditionally.
- `mic.listening` ("Đang nghe"), `mic.paused` ("Đã tạm dừng"), `mic.connecting`
  ("Đang mở mic…"), `mic.reconnecting` ("Mic giữ, chờ mạng"), `mic.denied` ("Chưa
  có quyền mic"): all five live only inside the six-string `state` switch in
  `micDockText`, which `isDemo` short-circuits past before it ever runs. Unreachable
  in demo by construction, not by coincidence of `isMicCapturing` being false.
- `listenTitle`/`listenBody` ("Đang nghe…" / "Chưa có lời nói..."): HANDOFF.md line
  30's empty-listening state. Gated on `isMicCapturing`, always false in demo, and
  additionally unreachable even for a single frame per the synchronous call-chain
  argument above. Demo shows `idleTitle`/`idleBody` instead at that moment, which
  make no mic claim.
- `idleTitle`/`idleBody` ("Sẵn sàng bắt đầu" / "Đặt iPhone giữa hai người... App
  nghe liên tục..."): approved instructional copy, not a claim that a mic is
  currently on - explicitly confirmed unchanged this round.
- `mic.recognizing`/`mic.translating` ("Đang nhận dạng" / "Đang dịch", and the
  `updating`/`translatingTag` variants used in `CaptionsTranscriptView`): per-segment
  transcription/translation pipeline status, not a microphone-hardware claim - the
  segment really is in that state per the fixture's own partial/final/translation
  timeline. Out of scope for this rule.
- `banner.denied` ("Sermiva chưa được cấp quyền micro."): asserts the opposite of
  mic access, not that it is active - out of scope for the rule regardless, and
  additionally unreachable in demo since `AutoGrantedMicPermission` never denies.
- `alertTitle`/`alertBody` (the OS permission dialog copy): never shown by this
  build - no real permission API is called in demo or anywhere else yet.
- `toastIOS`: never implemented in the app at all - prototype-only.

No string required a stop-and-ask; every case resolved by dropping the clause
(`endBody`) or by an already-true existing state (`idleTitle`/`idleBody` in place of
`listenTitle`/`listenBody`).

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
