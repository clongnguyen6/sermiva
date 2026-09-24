# Soniox routing and on-device translation contract

Decided 2026-09-22 against the public Soniox docs and the soniox-js SDK source of that date
(option B: two Soniox streams and a time-window join). After many review rounds the join still
showed translation fragments as complete, and the rule itself had a hole - see "Why option B was
stopped" below. The project owner stopped option B and chose **option C**, decided 2026-09-23:
one Soniox stream plus on-device Apple Translation for the owner's own speech. Model: `stt-rt-v5`.

## Decision

One `one_way` Soniox stream, unchanged from option B's stream M:

```json
{
  "api_key": "<from Keychain>",
  "model": "stt-rt-v5",
  "audio_format": "pcm_s16le", "sample_rate": 16000, "num_channels": 1,
  "enable_language_identification": true,
  "enable_speaker_diarization": true,
  "enable_endpoint_detection": true,
  "language_hints": ["<me>", "<target>", "<guest if specific>"],
  "language_hints_strict": false,
  "translation": { "type": "one_way", "target_language": "<me>" }
}
```

- This stream (still called M in the code and below) is the only source of segments: text,
  language, speakers, `<end>` boundaries, and the translation of every segment whose language is
  not `me`. This half is unchanged from option B and already works live on the owner's iPhone.
- There is no second Soniox stream and no join. A `me`-language segment's translation into `target`
  comes from Apple's on-device Translation framework instead, once that segment is final - see
  "Device translation" below.
- `guest` remains a recognition hint only. `target` is never sent to Soniox at all in option C - it
  is a purely on-device concept (see "Setup: key validation" below).

## Device translation

For every M segment whose language is `me`, once it is final: send its final `source` text (never a
partial/non-final tail) to Apple's Translation framework, vi -> en-US, and write the result to that
segment's `target` once, whole, when it returns. The input is exactly the segment's own final text,
so no attribution guess exists - unlike option B's join, which had to guess which of two
independently-segmenting streams' translations belonged to which window.

**Why Apple Translation, not a server round trip:** it is free, offline-capable, and removes the
second metered Soniox connection entirely. Vietnamese support was unverified going in - live
measurement is still outstanding, see "Unknowns" below.

### The narrow interface (owner requirement)

`TranslationSession` (Apple's type) can only be obtained inside a SwiftUI `.translationTask`
closure - there is no other public way to construct one. This means the actual `translate` call can
only ever happen inside `ConversationView`'s `.translationTask` closure (see the fatalError rules
below for why). Everything else - which segment is next, in-flight/queued bookkeeping, writing the
result back - is plain, testable Swift with no dependency on Apple's framework:

- `SessionControlling` (implemented by both `DemoSessionController` and `LiveSessionController`)
  exposes `translationConfiguration`, `makeTranslationRequests() -> AsyncStream<(id: Int, source:
  String)>`, and `reportTranslationStarted(id:) -> Bool`/`reportTranslationSuccess(id:target:)`/
  `reportTranslationFailure(id:)`.
- `LiveSessionController` forwards these to `SonioxLiveSession`, which owns `MeTranslationQueue` (the
  FIFO queue itself - no `TranslationSession` anywhere in it) and `SonioxJoinEngine` (which still owns
  `segments`, including a `me`-language segment's `target`/`translationInProgress`/`targetAbandoned`,
  via `applyTranslationStarted`/`applyTranslationSuccess`/`applyTranslationFailure`).
- `LanguageAvailability`'s own async calls sit behind `MeToTargetAvailabilityChecking`
  (`RealMeToTargetAvailabilityChecker` in production), so `LiveSessionControllerTests` can drive the
  gate/banner/config-once logic below with a fake status instead of the real, Simulator-unavailable
  framework.
- `ConversationView`'s `.translationTask` closure is the only place a real `TranslationSession` is
  ever touched - a `for await` loop over `makeTranslationRequests()`, sequential, one request at a
  time, reporting back by id. This closure is the "Apple adapter" - thin and untested, exactly like
  `SonioxStreamSocket` is for the Soniox wire format (AGENTS.md).
- `DemoSessionController.translationConfiguration` is always `nil`, so the closure never runs in
  demo; its `makeTranslationRequests()` returns an already-finished stream.

This is what lets `SermivaTests` exercise the queue's ordering/indicator/success/failure/abandon
rules with a fake standing in for the closure (driving the same `makeTranslationRequests`/
`reportTranslation...` contract the real closure drives, with a fake translated string instead of a
real `TranslationSession`), and what would let a different per-segment engine replace Apple later by
changing only that one closure.

### Two gates, not one (review round 2, finding 1)

The live session-start availability check does not merely drive the banner - it actually gates
whether anything is ever enqueued or translated, matching the documented "only `.installed`..."
contract literally:

1. **Enqueue-time gate** (`SonioxLiveSession.enqueueMeTranslation`): a `me` segment only ever reaches
   the queue at all while `isTranslationAvailable` is `true` - a flag `LiveSessionController` sets via
   `setTranslationAvailable(_:)` once its own check confirms `.installed`, reset to `false` at every
   session start (fail closed while that check is still in flight).
2. **Report-started gate** (`reportTranslationStarted(id:) -> Bool`): even a request that WAS
   legitimately enqueued can still surface from the queue's own long-lived, cross-session `AsyncStream`
   after it should no longer be honoured - availability dropped, or (see the ending section below) the
   session that enqueued it has since ended. Returning `false` here is what tells `ConversationView`'s
   closure to skip the actual `translate` call entirely for that request, never merely to discard its
   result afterward. `true` means the closure should actually call `translate` and show "Đang dịch…".

**The configuration itself is created at most once, ever, and only once `.installed` is actually
confirmed** - never for `.supported` or `.unsupported` (review round 2's explicit decision). Creating
it for `.supported` would let the very first `translate` call trigger the system's own download sheet
mid-session, with the mic already live - never acceptable. If a later session start finds the
language pack has since been removed, the (already-created) configuration is left exactly as it is
(fatalError rule 2 forbids touching it again) - only `isTranslationAvailable` and the banner move.

### Two independent guards on the result (review round 3, findings 2/3)

The async availability check's result is only ever applied under a compound guard -
`translationCheckEpoch == epoch && SessionPresentation.canEnd(for: state)` - and each half protects a
DIFFERENT stale-result shape, deliberately kept separable (each has its own test in
`LiveSessionControllerTests`, each independently red when removed):

- **The epoch half** protects against a check from an already-SUPERSEDED attempt applying during a
  LATER attempt's own `.requestingMic`/`.connecting` window - both `canEnd`-true, so `canEnd` alone
  cannot tell "this attempt's own still-running check" apart from "a stale check leaking in from the
  attempt before it". `translationCheckEpoch` is bumped at the start of every new attempt
  (`beginRequestingMic`), not only when its own check actually begins - review round 2 bumped it only
  in `prepareTranslationForSessionStart`, which was too late: the reviewer reproduced a stale result
  from an ended session applying during the NEXT attempt's own `.requestingMic`, surfacing as the
  banner staying up on an idle screen once that next attempt's capture then failed.
- **The `canEnd` half** protects against a check resolving after its OWN attempt has already ended or
  aborted, with no new attempt having started yet - the epoch is unchanged in that case (ending does
  not itself bump it), so only `canEnd` catches it.

### A request enqueued after genuine stream termination (review round 3, finding 1)

`MeTranslationQueue.makeRequests()`'s returned `AsyncStream` can genuinely terminate (the view
disappearing, the task cancelled) independently of a "re-run" ever happening. Before this fix,
`continuation` was left pointing at the dead stream after termination, so a request enqueued in that
window silently disappeared - `continuation.yield` on an already-terminated continuation is a
documented no-op, and the request was never in `bufferedBeforeStream` either, so it was neither
delivered nor abandoned. `handleTermination` now clears `continuation` too, so a post-termination
`enqueue` falls back to buffering - delivered whole on a genuine re-run, or abandoned along with
everything else if `abandonAll` runs instead. See `MeTranslationQueueTests`.

### The eight fatalError rules (owner-confirmed against Apple's docs)

Apple: "The system throws a fatalError if you use a [session] instance after the attached view
disappears or if you use it after changing the configuration." Checked by file:line in every
handoff:

1. `TranslationSession` appears only as the `.translationTask` closure parameter - never assigned to
   a property, captured by a stored closure, or passed out of the closure. Every `translate` call is
   made inside that closure.
2. `TranslationSession.Configuration` is created at most once per controller - and only once
   `.installed` is actually confirmed, never for `.supported`/`.unsupported` (see "Two gates, not one"
   below) - then never reassigned, `invalidate()`-ed, or set back to `nil`. The language pair never
   changes mid-session (HANDOFF section 4 already forbids changing `me`/`target` mid-session).
3. `.translationTask` is attached to the root `ZStack` of `ConversationView.body` - the one view that
   lives for the whole conversation (`RootView`'s `.liveConversation` case; sheets only ever cover
   it, never replace it). Never attached in `RootView`. The configuration comes from the controller
   through `SessionControlling`, and is `nil` in demo, so the demo closure never runs.
4. `makeTranslationRequests()` returns a fresh `AsyncStream` every call, so a re-run of the closure
   (should SwiftUI ever re-invoke it) never double-consumes a stream still wired to a previous run.
   `MeTranslationQueue` tags each stream with its own generation, so a SUPERSEDED stream's belated
   `onTermination` (it can fire well after a newer stream already exists) can never abandon the newer
   stream's own pending requests - review round 2's finding 3. A GENUINE termination (no re-run at
   all) also clears `continuation`, so a request enqueued afterward is buffered rather than silently
   lost - review round 3's finding 1. See "A request enqueued after genuine stream termination" below
   and `MeTranslationQueueTests`.
5. Inside the closure, `translate` calls are sequential - at most one is ever awaited at a time (a
   plain `for await` loop, no child `Task` spawned per request).
6. Every `catch` in the closure, and the stream's own `onTermination` (the view disappearing, or the
   task being cancelled), marks the affected queued/in-flight ids abandoned and clears "Đang dịch…".
   Abandoning never finishes the stream itself (it must keep working for the next session, per rule 3)
   - so a request already sitting in its buffer before the abandonment still surfaces later; that is
   exactly what `reportTranslationStarted`'s `Bool` return exists to catch (review round 2, finding 2).
7. "Đang dịch…" for a `me` segment is true only from the moment the closure actually calls
   `translate` for that id (`reportTranslationStarted` returned `true`) until it returns or throws -
   being merely queued does not count (AGENTS.md's activity-indicator invariant).
8. `me != target` is enforced before the configuration is created. Empty/whitespace-only source is
   never sent. Every error means "no translation" - never retried automatically. See "Two gates, not
   one" above for how "only `.installed` enqueues/translates" is actually enforced, not just implied.

Other iOS 18 rules: resolve `vi`/`en` against `LanguageAvailability().supportedLanguages` by
`languageCode`, preferring `en-US` when several English entries exist (`TranslationLanguages.swift`);
pass the resolved values to both `status(from:to:)` and the configuration; log the resolved
identifiers once, with `os.Logger`, never any text. At every live session start, the controller calls
`LanguageAvailability().status(from:to:)`: `.installed` runs translations; anything else shows no
translation and no indicator for the rest of that session, plus the banner below.

## Setup: key validation (target is not a Soniox concern)

`GET https://api.soniox.com/v1/models` with `Authorization: Bearer <key>`, exactly as before. The
model must support one-way translation into `me` (and list `guest` when `guest` is a specific,
non-auto language) - `target` is never checked against Soniox at all in option C, since it is
translated on the device, not by a second stream. `GET /v1/concurrency-limits` then checks for at
least **1** simultaneous connection (was 2 under option B).

## Setup: on-device download step (owner decision)

Right after a successful "Kiểm tra và tiếp tục", before any metered session:
1. Setup checks `status(from:to:)`.
2. `.installed`: continue with no prompt - the expected path on the owner's phone, where Vietnamese
   and English (US) are already downloaded.
3. `.supported`: `SetupView` sets its own `@State` configuration (initially `nil`) to vi -> en-US.
   That runs `SetupView`'s own, separate `.translationTask` closure, which calls
   `try await session.prepareTranslation()` - the system shows its own permission sheet and
   progress, which this app cannot restyle. No session is stored anywhere.
4. `.unsupported`, a decline, or an error: continue to the conversation regardless - the live
   session-start check then shows the banner below if it is still unavailable.

**Single-shot, honest handoff (review round 2, finding 4):** the whole window from tapping "Kiểm tra
và tiếp tục" through this download check actually settling is one `isProcessing` state in `SetupView`
(`validationState == .checking || keyPendingTranslationCheck != nil`), and BOTH
"Kiểm tra và tiếp tục" and "Dùng thử bản demo" are disabled for its entire duration - not just during
the network call. Before this fix, the download check's own async window left both buttons live: a
second tap could set `translationDownloadConfiguration` a second time, and tapping "Dùng thử bản demo"
mid-check could switch straight to demo only for the still-pending `onKeyValidated` to yank the user
back into live moments later. "Dùng thử bản demo" is only ever tappable while nothing else is in
flight, so once the user is in demo, no leftover key-validation work is still pending to later switch
them into live behind their back.

## Banner when vi -> en is unavailable (owner decision)

HANDOFF 2.2's "info" banner variant - `surface` background (not `surface2`), `text2` icon/text colour
(not `text3`) - matched against the prototype's own `bannerStyle` (`design/claude-handoff/
Sermiva.dc.html` `~1226`, the `isBannerInfo` branch). The GEOMETRY (padding `10 10 10 14` - an extra
4 pt on the leading edge - margin `4 16 6`, and a 10 pt gap between items) is shared by ALL FOUR
`ConversationView` banners, info or not, via one `BannerStyle` view modifier - review round 3, finding
5 caught the three older (danger/warn) banners still using a uniform 10 pt padding, which the prototype
never actually distinguishes by variant; only the background (and, upstream of the shared modifier,
the icon/text colour) depends on `isBannerInfo`. Lowest priority among `ConversationView`'s banners
(mic-denied, auth-error and network-lost all take precedence). Text, verbatim: **"Lời của Bạn sẽ
không được dịch sang tiếng Anh trên máy này."** Visible only from the live session-start availability
check through the rest of that session - cleared immediately on a failed connect too (review round 2,
finding 5: the check can resolve, and set the banner, before the connect attempt itself fails) - and
never in demo (`DemoSessionController.showsTranslationUnavailableBanner` is always `false`).

## `target` mapping and "Đang dịch…" (from `Segment`)

- `lang != me`: unchanged from option B - M's own translation chunk following the segment's original
  chunk, set when final. "Đang dịch…" reflects a live M-direct signal exactly as before.
- `lang == me`: `target` is `nil` until the on-device queue's `reportTranslationSuccess` lands it,
  `nil` forever once `reportTranslationFailure`/an abandon lands (`targetAbandoned = true`).
  "Đang dịch…" (`translationInProgress`) is true only between `reportTranslationStarted` and
  whichever of success/failure/abandon follows - never while merely queued (fatalError rule 7).

## Session lifecycle (single socket)

Unchanged from option B for everything M itself does: connecting, listening, paused (keepalive every
10 s), reconnecting (exponential backoff 1 s/2 s/4 s/…/30 s, one retry per outage - now also
preempted the instant the network path becomes available again, see below - the open segment at the
moment of a drop closed like a genuine `<end>` only if it had accumulated any final text, speaker
letters reset), ended (`finalize`, `<fin>`, empty frame, close on timeout). What changed: there is
exactly one socket, so reconnect no longer needs a shared-audio-origin requirement between two
sockets, and the audio buffer (60 s of 16 kHz mono Int16, oldest dropped beyond that) is simpler - it
just waits for the one socket's config to be accepted, not two.

### Reconnect speed, audio continuity, and connection accounting (review round 4, owner decisions)

- **Outage audio is kept, unchanged (finding 2, reconfirmed):** audio captured during an outage stays
  in the existing 60 s `bufferedAudio` buffer and is sent after reconnect, exactly as before - this is
  what the "Mất mạng. Nội dung được giữ." banner already promises. No code changed for this item.
- **Reconnect speed:** in addition to the exponential backoff above, `SonioxLiveSession` also
  reconnects the instant iOS's own `NWPathMonitor` (wrapped by `NetworkPathMonitoring`/
  `RealNetworkPathMonitor` - a system framework already linked into the app, not a new dependency)
  reports the network path is available again while a reconnect is pending. This does not reset
  `reconnectAttempt` (a flapping network reporting "available" repeatedly must not reset backoff to
  its shortest delay every time) and preserves the single-pending-attempt/max-one-connection
  guarantees: a `reconnectScheduleToken` counter invalidates whatever backoff timer is still pending
  the instant the path-triggered reconnect fires, so a stale timer that fires anyway afterward is
  recognised and does nothing.
- **Never show an empty segment (finding 6):** the segment open at the moment of a drop is now
  closed like a genuine `<end>` only if it had accumulated any final text; one with none is discarded
  outright (`SonioxJoinEngine.closeSegment`) rather than displayed. Live evidence: the second mock
  session's Console log traced back to a "Người nói A" segment with no text and no language, from a
  purely non-final open segment closed at a drop.
- **Resend audio never confirmed finalized (finding 3):** `SonioxLiveSession` keeps a second, separate
  rolling buffer (`unfinalizedSentAudio`, bounded to 15 s / 480,000 bytes - independent of, and
  smaller than, the 60 s outage buffer above) of audio already sent to the current socket but not yet
  confirmed finalized by it, trimmed from the front on every response using Soniox's own
  `final_audio_proc_ms` (converted to bytes at the fixed 32,000 bytes/s rate). On reconnect, this
  buffer is resent to the new socket FIRST, before the outage buffer, so speech Soniox had not yet
  finalized when the drop happened is re-recognized rather than lost forever - live evidence: the
  first mock session's last words before a drop were lost this way, since the open segment kept only
  its final text and the audio for the rest had already gone to the dead socket. Combined with
  finding 6 above, the pre-drop non-final tail was never shown as a segment, so the resend's
  re-recognition lands as one new segment, never a duplicate of one already on screen
  (`SonioxLiveSessionTests.test_reconnectResendOfUnfinalizedAudioDoesNotProduceADuplicateSegment`).
  The outage buffer's own bound and clearing rules are unchanged, but its flushed audio now also
  feeds into the same finalized-tracking, so it too becomes resendable if the new socket drops again
  before Soniox finalizes it.
  **Round 5, finding B2, and the review of 54b3202, finding 3:** `final_audio_proc_ms` is CUMULATIVE
  for the whole connection, so it is a stream position: everything the connection received before it
  is finalized. `unfinalizedSentAudio` is always a contiguous tail of what the current connection
  received, and `SonioxLiveSession` tracks the stream position of its first byte
  (`unfinalizedStartByte` - 0 for a new connection, whose own stream starts with the resent audio).
  Each response drops exactly the bytes before the confirmed position; the 15 s bound also drops from
  the front, moving the same start forward. Round 5 tracked only a watermark and assumed the buffer's
  front sat at it, so once the 15 s bound had dropped from the front, confirmed progress was trimmed
  from audio that was never finalized: a 20 s outage, then a second drop with 2 s confirmed, resent
  seconds 8-20 instead of 6-20; with 15 s confirmed it resent nothing instead of 16-20.
  **Exactly what the bounds drop:** when an established connection drops, the next connection to be
  established first receives `[max(confirmed, sent - 15 s), sent)` of the dropped connection's own
  stream - the unconfirmed part of its last 15 s - then the most recent 60 s of audio captured while
  no connection was established (the outage buffer), then live audio. Both bounds now cut to the byte
  rather than to whole capture chunks (every cut is a whole number of 16-bit samples). Everything
  else is dropped: unconfirmed audio older than the dropped connection's last 15 s, outage audio older
  than the most recent 60 s, and everything still waiting when the session ends with no connection
  (the end grace wait below expired, or Kết thúc during the first connect).
- **Connection accounting - still unexplained (finding 1/A):** the owner's filtered Console log from a
  mid-session reconnect on 8846c89 showed every `SonioxTranslationStatusShape` line printed twice,
  less than 1 ms apart, right after that reconnect. The screen stayed correct throughout. What is
  established is only that the lines appeared twice in the Console: at 8846c89 those lines carried no
  socket or session id, so the log cannot tell the open hypotheses apart:
  1. two `LiveSessionController`/`SonioxLiveSession` pairs were alive, each with its own socket;
  2. a superseded socket's task never really completed, and kept receiving;
  3. the logging pipeline (or the way the log was captured or viewed) duplicated lines.
  Code reading found no path that feeds one audio stream to two live sockets, and found that
  `connectFresh` closes the previous socket before creating another - that is reading, not proof.
  Round 5's argument that an abandoned socket object "should simply deallocate" was wrong for 54b3202
  itself: round 5 gave every socket its own `URLSession` with `delegate: self` and never invalidated
  it, and a `URLSession` holds its delegate strongly until it is invalidated, so every socket object
  leaked (review of 54b3202, finding 5 - fixed, see "Connection lifecycle" below). 8846c89 had no
  session delegate, so this leak does not explain the 8846c89 evidence either. The ids added in round 5
  (`LifecycleIds`, `ConnectionLifecycleLogging.swift`), now on every socket line together with the
  owning session's id, exist so the owner's next live session can answer this - see "Reading the
  lifecycle log" below.
- **A delayed close must only ever close the socket it was scheduled for (round 5, finding B1,
  blocking):** `end()`'s 1.5 s close used to read `self.socket` fresh when it fired, so "Phiên mới"
  inside that window could have its NEW socket closed. The close timer is now invalidated by a token
  as soon as anything else closes the session's connection, and "Phiên mới" closes the ending
  connection itself, at once, before opening the new one - its transcript has just been cleared, so
  its `<fin>` answer has nowhere to go
  (`SonioxLiveSessionTests.test_endsDelayedCloseNeverClosesANewerSessionsSocketStartedDuringTheWait`).
- **Ending mid-reconnect waits, rather than discarding buffered audio (finding 4b, refined in round 5
  and in the review of 54b3202):** pressing Kết thúc while the connection is down waits a fixed, short
  (3 s) grace period before actually ending, instead of closing the socket immediately - live
  evidence: the first mock session lost its last two sentences exactly this way. This is a simple
  timeout, not a "wait until confirmed flushed" mechanism, which would have no bound if the network
  never came back at all. "Down" includes a paused session whose connection dropped: its unsent audio
  from before the pause is waiting just the same (round 5 ended that case at once; the invariant test
  found it). If the connection comes back during the wait, the waiting audio is sent at once, and the
  wait still ends at 3 s with finalize - so an end completes within 3 s + the 1.5 s close window.
  **Lead ruling, round 5, finding 5:** the mic stops the INSTANT Kết thúc is confirmed - only audio
  already captured before that point is ever flushed during the wait, never anything captured during
  it. `state` itself stays what it was (`.reconnecting` or `.paused`; `.listening` if the connection
  comes back) - no new state; the dock's truth comes from `isMicCapturing` -
  `SessionPresentation.micDockText`'s "Mic giữ, chờ mạng" line also requires `isMicCapturing`, so it
  falls back to the existing "Mic tắt" line once the mic has genuinely stopped - no new copy.
  **Round 5, finding 4/7:** both "Tạm dừng"/"Tiếp tục" and Kết thúc itself are inert for the whole
  wait - `LiveSessionController.isEndPending` (`@Published`, exposed on `SessionControlling`) gates
  `canEnd` (so Kết thúc cannot reopen `EndSessionSheet` mid-wait) and is checked at the top of
  `primaryButtonTapped` (so pause/resume cannot run at all, not just visually disabled).
  **Round 5, finding B3:** auth wins - a rejected key arriving during the wait invalidates the wait's
  own scheduled closure (a token), so the pending `.ended` can never overwrite `.authError`, lose the
  auth banner, and leave the rejected key in Keychain with no "Nhập lại khóa" ever shown for it.
  **Review of 54b3202, findings 1-2 (replaces round 5's finding B4 fix):** a running session's
  displayed state is decided in one place, `LiveSessionController.runningState`, from two independent
  levels: whether the user paused, and whether the connection is established (as `SonioxLiveSession`
  last reported it). Round 5 inferred it from the last transition and dropped `onReconnected`/
  `onDisconnected` whenever they arrived while paused: pause during a reconnect, the connection comes
  back while paused, resume - and the screen stayed "Đang kết nối lại…" with "Mất mạng" on a live
  connection forever; pause, the connection drops while paused, resume - and the screen claimed
  `.listening` with no connection at all.
- **Initial connect failure shows a banner (finding 5):** previously, a failed FIRST connection
  (never a mid-session reconnect - that already has "Mất mạng") returned silently to `.idle`. It now
  shows the approved prototype's own string, in the existing (non-info) banner style: **"Lỗi mạng,
  thử lại sau"** (`design/claude-handoff/Sermiva.dc.html` ~810, Settings' key-status object, key
  `network`). Cleared once a LATER "Bắt đầu" attempt actually succeeds - never merely by retrying.
  Never shown for a genuine auth rejection (that already goes to its own banner), and never in demo
  (`DemoSessionController.showsNetworkErrorBanner` is always `false`). **Round 5, finding C9:** also
  cleared on a LATER attempt failing for a non-network reason (a mic capture failure) - the banner
  shows only while it is actually true, and a mic failure is a different failure entirely, not a
  network one.

### Connection lifecycle (review of 54b3202)

Five review rounds each fixed the listed bugs and then found new ones in the interactions between
drop, reconnect, pause, resume, end, auth and path events. The owner decisions above are unchanged;
the structure that carries them is now:

- **One place decides the connection.** `SonioxLiveSession.phase`: `inactive`, `starting` (the first
  connection in flight), `streaming` (config accepted), `reconnecting` (no established connection: a
  backoff timer pending, or an attempt in flight), `ending` (finalize sent, waiting for the connection
  to close). `handle` decides every socket event from the phase. A socket's events count only while it
  is the session's current socket - by object identity, since each socket object is used for exactly
  one attempt - which replaces round 5's generation counters. Timers are cancelled by tokens.
- **One place decides the screen:** `LiveSessionController.runningState`, above.
- **End.** Finalize and the empty frame go to the established connection; until it closes (the server
  closes it, or 1.5 s pass), what it returns is applied, so the `<fin>` answer finalizes the last
  utterance. Review of 54b3202, finding 4: round 5 marked the connection stale before sending
  finalize, so the answer was discarded and the last utterance stayed an unfinished draft - which
  undercut the end grace wait's whole purpose. With no established connection there is nothing to
  finalize, and an attempt still in flight is closed at once. M-direct translations still in progress
  are abandoned when the connection closes rather than at Kết thúc, since the `<fin>` answer may still
  complete them. On-device translation still queued or in flight is abandoned at Kết thúc exactly as
  before. A `me` segment that only the `<fin>` answer finalizes is still enqueued and translated
  after Kết thúc (choice (c), decided below), so it gets its English line.
- **Auth wins until the session has fully closed.** A rejected key reported by any socket the session
  opened, including one already superseded, moves the screen to `.authError` - also during the end
  grace wait, and during the close window after Kết thúc, where round 5 ignored it (the screen kept
  "Đã kết thúc" on a rejected key with no "Nhập lại khóa"). After the connection has closed, or after
  "Phiên mới", a straggler is ignored.
- **Socket objects are released.** `SonioxStreamSocket` creates its `URLSession` in `connect()` and,
  in `close()`, cancels the task and then calls `finishTasksAndInvalidate()`, which lets the cancelled
  task report completion to the delegate and then drops the session's strong reference to it
  (finding 5). This is adapter code and stays untested (AGENTS.md); the new "URLSession invalidated"
  and "object deinit" log lines are how a live session can confirm it.
- **Backoff resets only once a connection has proven healthy (reviews of 2046102, item 5, and
  46e9ca0, item 3).** Soniox sends no explicit "config accepted" message. The socket reporting its
  config SENT proves nothing, and neither does one server answer: resetting on the first response
  (the 2046102 fix) let a server that answers once and closes be reconnected every second, forever,
  each connection metered. The criterion now: `reconnectAttempt` resets only once a connection has
  stayed established for 30 s - as long as the longest backoff delay - not when the config is sent,
  not on a response, and not on a drop. Anything shorter-lived keeps backing off 1 s, 2 s, 4 s … 30 s.
  The price: a network that drops every connection after, say, 20 s also reaches the 30 s delay, even
  though each connection worked for a while. A non-auth server error is not reported as a response
  at all (adapter); the close that follows it drives the reconnect.
- **Keepalive runs on the session's own scheduler (item 6).** Every 10 s while paused, through the
  same `DemoScheduler` as every other session timer, stopped by a token - so it cannot survive Kết
  thúc, an auth rejection or "Phiên mới", and the invariant test can see every keepalive.
- **An interruption pauses the session in any running state (item 4).** A call, Siri, a
  media-services reset or a lost input route stops capture; `handleCaptureStoppedExternally` now
  pauses from `.connecting` (the state becomes `.paused` the moment the connection is established),
  `.listening` and `.reconnecting`. Round 5 only paused from `.listening`, so an interruption while
  connecting or reconnecting later showed `.listening` - "Đã kết nối", a "Tạm dừng" button, a
  recognizing caret - with the mic off. While `.connecting` - for however long the connect takes;
  nothing bounds it - the dock says "Mic tắt" with the neutral dot (review of 46e9ca0, item 2): the
  live app opens capture before it connects, so a stopped mic while connecting was stopped, not being
  opened, and "Đang mở mic…" with the warning dot now shows only while the permission answer is
  pending. `RealAudioCapture` does not restart capture when an interruption ends; Tiếp tục does.
- **Only the current path monitor counts.** A cancelled monitor's last callback can still be on its
  way (the real one hops to the main actor); it is ignored, so a previous session's monitor can never
  start an attempt in the next session.
- **Translation requests carry their session.** Each on-device request records the session epoch it
  was made in; a report for a request from any other session is dropped, so a late result can never
  land on a later session's same-numbered segment - whatever the queue's own stream still holds.
- **The previous session is let go of at the tap (review of 46e9ca0, item 1).** Bắt đầu and Phiên mới
  call `SonioxLiveSession.discardPreviousSession()` first, before the mic-permission answer (which
  arrives asynchronously, after any delay) or capture (which can fail and then never reaches
  `start()`). It closes a connection still closing after Kết thúc, advances the session epoch, and
  abandons the old session's on-device translation silently - so nothing of the old session can act
  or reappear, however long the new attempt takes to start, or whether it starts at all. Before this,
  the epoch advanced only in `start()`, which is why flipping choice (c) was not a one-line change.
- **A permission answer only applies to the attempt that asked, while it still waits.** Kết thúc is
  reachable while the answer is pending; a late answer used to start a session behind "Đã kết thúc",
  and an older attempt's answer could land on a newer one (found once the invariant test made the
  answer asynchronous).

**The invariant test** (`SermivaTests/LifecycleInvariantTests.swift`) drives the real controller and
session through fake sockets (app-owned events only, no Soniox JSON), a virtual clock behind both
schedulers, fake path monitors, fake capture (with interruptions and start failures), a fake
mic-permission provider that answers asynchronously when the test says (granted or denied), a fake
availability check the test resolves when it chooses, and a fake translator driven exactly the way
`ConversationView`'s `.translationTask` closure drives the real one. Server closes, connect failures
and path events are generated in every phase they can happen in: the first connect, the grace wait,
the close window after Kết thúc, and after the `<fin>` answer. An oracle that tracks ground truth on
its own checks after every event: (a) at most one open connection, and none ever opened outside a
running session; (b) the screen's state, dock line and dot, end-pending flag and banners match the
real connection and mic; (c) every connection receives exactly the audio the bounds above say, in order,
and nothing else; (d) the transcript shows every piece of finalized audio exactly once; (e) auth
wins; (f) an end completes within its bound and the `<fin>` answer is applied; (g) nothing -
connection, path monitor, audio, transcript - crosses into the next session; (h) the path monitor
runs exactly while a session runs, a reconnect attempt starts exactly when the documented backoff
says (resetting only after a connection stayed established for 30 s), and a path-available event
while waiting starts one at once; (i) a translation lands only on the segment it was made for, "Đang dịch…" shows exactly while
a real call for that segment runs, and no call starts before `.installed` or after Kết thúc; (k) a
keepalive goes out while paused on an established connection, never more than 10 s after the
previous one - checked at each keepalive - and never otherwise. It was red against 54b3202 and,
extended, against 2046102 and 46e9ca0 (each test commit comes before its fix). A failure prints the seed and a shrunk minimal sequence with the state after every step.

The committed seed count keeps `./scripts/verify.sh` fast. To scale it locally, put the variables in
xcodebuild's own environment with a `TEST_RUNNER_` prefix, which xcodebuild strips before passing
them to the test process: `TEST_RUNNER_SERMIVA_FUZZ_SEEDS=30000 TEST_RUNNER_SERMIVA_FUZZ_SEED_BASE=1
xcodebuild … test`. Written after `xcodebuild` as `NAME=value` arguments they become build settings
and never reach the test. The test does not cover the real `Timer`s left (the controller's elapsed
counter), the real service, the adapters, or real audio hardware.

**Choices awaiting the owner** (each is what the invariant test asserts): the grace wait also
applies to a paused session whose connection is down; auth arriving in the close window after Kết
thúc moves `.ended` to `.authError`.

**Choice (c), decided by the owner on 2026-09-24: yes.** A `me` segment finalized only by the `<fin>`
answer after Kết thúc is still translated into English. It is one constant,
`SonioxLiveSession.translatesSegmentsFinalizedAfterEnd`, now `true`: such a segment is enqueued while
the connection closes and translated after Kết thúc; the result lands on the ended transcript, and
"Đang dịch…" never shows, since the screen is not running. The tap of Bắt đầu or Phiên mới abandons
whatever is still queued or in flight (`discardPreviousSession`), and the session-epoch guard drops
any late result. The invariant test reads the constant. Evidence that `true` holds every invariant:
the full `SermivaTests` suite plus 5,000- and 10,000-seed fuzz runs with the switch `true` passed,
reproduced by an independent review.

**Device-only follow-up, pre-existing and unproven** (not fixed; the invariant test does not model
it): `RealAudioCapture` does not observe `AVAudioEngineConfigurationChange`. If the engine stops for
a configuration change, nothing reports it, and the dock could keep saying "Đang nghe" with no audio.

### Reading the lifecycle log (next live session)

Console.app, with the iPhone selected, search `subsystem:com.clongnguyen6.sermiva`. That shows both
categories interleaved - `SonioxConnectionLifecycle` and `SonioxTranslationStatusShape` - which a
category filter would split apart (round 5's suggested filter named only the first, so it could never
show the duplicated diagnostic lines next to the lifecycle lines). No line carries a key, text, or
URL. Lines, each with its own object's small integer id:

- `controller #C created` / `deinit`, and `controller #C state .listening` (every state change).
- `session #S created` / `deinit`, `session #S start() called in phase …`, `session #S opening
  connection attempt #K of this session on socket #N`, `session #S socket #N streaming`, `… dropped`,
  `… failed before connecting`, `session #S closing socket #N in phase …`, `session #S end() called in
  phase …`, `session #S auth rejected by socket #N …`.
- `session #S socket #N [M] task created (connect attempt) - K real tasks open now`, `… close() called
  by the app`, `… task ACTUALLY completed - K real tasks open now`, `… URLSession invalidated`, `…
  object deinit`, `… server error code N` (a non-auth error; the close that follows drives the
  reconnect).
- `session #S discarding the previous session in phase …` (every Bắt đầu / Phiên mới tap) and
  `session #S connection healthy for 30 s - backoff reset`.
- `session #S socket #N [M] stream M saw a new translation_status value: …` and `… marker <fin>
  carried translation_status: …` (category `SonioxTranslationStatusShape`).

What each hypothesis would look like when a diagnostic line appears twice:

1. **Two controllers or sessions alive:** the two copies carry different `session #` ids, and both
   sessions (or two `controller #` ids) have a `created` line with no `deinit` before the duplicate.
2. **A task never truly completed:** the two copies carry different `socket #` ids under the same
   session; the older socket has `close() called by the app` but no later `task ACTUALLY completed`,
   and "real tasks open now" stays above 1.
3. **The logging pipeline duplicated lines:** the two copies are identical, ids included, and only one
   socket id is between `task created` and `close()`. One socket object never logs the same "saw a new
   translation_status value" twice (it keeps a per-object set), so an identical pair of those lines
   can only have been duplicated after it was logged.

**On-device translation is independent of the Soniox socket entirely.** An M reconnect never
abandons an in-progress `me`-language translation (`SonioxJoinEngine.abandonMDirectTranslationsInProgress`
only ever touches non-`me` segments) - Apple's Translation framework does not care whether Soniox is
connected. Only the whole session ending (`end`/`endImmediately`) abandons whatever the on-device
queue still has queued or in-flight, via `MeTranslationQueue.abandonAll` - the queue's own
`AsyncStream` and `.translationTask`'s consuming `Task` are NOT torn down then, since they live for
the whole conversation across "Phiên mới" (fatalError rule 3); only the pending requests are
abandoned. Translation-request ids are drawn from a counter that never resets across "Phiên mới"
(unlike Soniox segment ids, which do reset per `SonioxJoinEngine`) - this is what stops a stale,
still-in-flight translation from a just-ended session ever landing on a same-numbered segment in the
next one; see `SonioxLiveSessionTests.test_aStaleReportFromAnEndedSessionNeverLandsOnTheNextSessionsSameNumberedSegment`.
Abandoning removes that id's tracking, but a request already sitting in the queue's own stream buffer
before the abandonment still gets pulled out by a later `for await` - "Two gates, not one" above (and
`test_endedSessionsQueuedRequestStillSurfacesButMustNeverBeStarted`) is what actually stops it from
ever reaching `translate`.

## Why option B was stopped

In reproducible token orderings the window-based join showed a translation fragment as if it were a
complete translation - concatenating whatever a completed T-chunk had collected so far, with no way
to tell "this chunk is genuinely done" apart from "T just hasn't sent more yet". The chunk-boundary
rule itself (original run, then translation run, ending on the next original or a marker) had a hole
around chunks that straddled two M windows or matched no window at all - each fix uncovered another
edge case (see git history for the sequence of "critical repro" fixes). Inter-stream timing (do M and
T report `start_ms` on a truly shared clock) was never confirmed against a live session either. Two
metered streams also cost 2x. None of this affects `me`-language segments in option C at all, since
there is no second stream's timing to trust.

## Fallback if option C misbehaves live

Reconsidered only if a live session shows the on-device path is genuinely broken (translations never
land, or land on the wrong segment): ship `guest -> me` only (stream M alone, exactly as it already
works) and do `me -> target` later, once the cause is understood. This is a strict subset of what
already ships - removing on-device translation only ever removes `target` for `me`-language
segments, never anything else.

## Stream contract (from docs, unchanged from option B)

- `wss://stt-rt.soniox.com/transcribe-websocket`. Config as first text frame, audio as binary frames
  at real-time pace or faster (408 otherwise), control frames `{"type":"keepalive"}` and
  `{"type":"finalize"}`, empty frame to end.
- Response: `tokens[]`, `final_audio_proc_ms`, `total_audio_proc_ms`, `finished` on the last message.
  Errors: message with `error_code`, `error_type`, `error_message`, `request_id`.
- Token: `text`, `is_final`, `confidence`, `start_ms`/`end_ms` (spoken tokens only), `speaker` (string
  number), `language`, `source_language` (translated tokens only), `translation_status` in
  `none | original | translation`.
- Non-final tokens are replaced in full on every response. Final tokens arrive once.
- Marker tokens `<end>` and `<fin>` are final and are stripped from text. Not documented as reliably
  tagged `.original`/`.none` - the app checks marker text before dispatching on `translation_status`
  at all, so a marker always closes the segment regardless of its status and never becomes displayed
  or translated text.
- Keepalive at least every 20 s when no audio flows; 5-10 s recommended. The keepalive page says a
  stream is charged for its full duration.
- 300 minutes per stream, fixed; 413 means reconnect. 401, 402, 403 are auth-class. 503 "cannot
  continue request" means restart with backoff. 429 means the project or organization concurrency
  cap (default 10 simultaneous connections per the limits page); `GET /v1/concurrency-limits` reports
  it.
- Endpoint detection reduces diarization accuracy (documented). Accepted.
- No overlap signal exists. "Nói chồng" is never rendered from a live session; the app still treats
  overlapping speech itself as an expected case, not an error (HANDOFF section 6, demo-data.json) -
  it just never claims a badge the service never sent.

## Live measurements

**First option-C live session (owner, iPhone "Long"):**

- vi -> en via Apple worked, with complete sentences - e.g. "Có chuyện gì vậy?" -> "What's going on?",
  and an 8-sentence paragraph translated in full. en -> vi via Soniox still worked, and no banner
  appeared (status was `.installed`).
- vi -> en latency: the owner reports it as negligible and fine for use. Not timed per sentence.
- Pause billing: not measured - the Soniox Console was not accessible to the owner during this
  session.
- Overlap: no "Nói chồng" badge appeared (correct - no service signal), and both speakers were still
  transcribed and translated.
- The download sheet was not exercised: the key was already saved, so Setup was skipped. The
  session-start status check reported `.installed`, and translation ran.
- The `translation_status` shape log was not read yet.
- The mic-denied banner and "Mở Cài đặt iPhone" were seen live.
- Airplane mode before start: the session could not start (see "Airplane mode before start" below for
  exactly what the screen shows). Mid-session reconnect is not yet tested.

**Second mock-conversation live session (owner's iPhone, from commit 8846c89):**

- No duplicate segments, no empty segments, and no misattributed translations across the whole
  session.
- Overlap: Soniox dropped part of one overlapping voice rather than inventing or misattributing
  anything - consistent with "no overlap signal exists" above; the app did not fabricate any text.
- The two sentences spoken after the network returned were both present, because the owner waited
  ~30 s before ending. Network back to reconnected took roughly that same ~30 s, entirely spent in
  backoff - the live evidence behind this round's `NWPathMonitor`-triggered immediate reconnect
  (see "Reconnect speed" above), which did not exist yet during this session.
- Every `SonioxTranslationStatusShape` line printed twice after the reconnect (finding 1 above) - seen
  in the owner's filtered Console log, not on screen; the screen stayed correct throughout. Its cause
  is not established - see "Connection accounting" above.

**Third mock live session (2026-09-24, 16:52-16:58, build 5dcef10, iPhone "Long"):**

- With airplane mode on, the initial-connect network banner "Lỗi mạng, thử lại sau" appeared (status
  "Sẵn sàng", dock "Mic tắt").
- All 17 scripted sentences appeared, except the parts Soniox did not recognise in the two
  overlapping turns. No duplicate segments, no empty segments, and no misattributed translations.
- Lifecycle log: at most one real task was open at any time. Every socket that was closed showed
  "task ACTUALLY completed", "URLSession invalidated" and "object deinit". No diagnostic line was
  duplicated. Kết thúc closed the last socket, leaving 0 open.
- The log has a gap from 16:57:36 to 16:57:58 while airplane mode was on, probably because Console.app
  receives the device log over the network. Attempts #3 and #4 were not observed.
- Two-socket bug, the owner's words verbatim: "đã sửa trong code và qua review; chưa quan sát trọn một
  lần nối lại vì log hở từ 16:57:36 tới 16:57:58". Not closed.
- The resend of unfinalized audio was not specifically exercised: the last pre-drop sentence was
  finalized 2 s before the drop.
- Pause billing: still not measured.

**Still not yet measured, for the next session:**

- Pause billing - read from the Soniox Console (whichever usage unit it displays) before and after a
  pause: usage before, pause duration, usage after, and whether the figure moved by roughly the pause
  duration.
- Per-sentence vi -> en latency, timed (not just "negligible") over at least five sentences of
  different lengths.
- The `translation_status` shape log, read off the Console/device log.
- Mid-session reconnect (network lost while a session is already running).

## Segment mapping (from stream M)

`Segment { id; speaker; lang; source; target; isFinal; startedAt; overlap; targetAbandoned;
translationInProgress }`

- `id`: app-assigned, increasing per session (per `SonioxJoinEngine` instance - resets on "Phiên
  mới", unlike the translation-request counter above, which does not).
- Boundary: new segment on the first original token after `<end>`, or when a final original token
  changes `speaker` or `language` from the open segment's locked values **at a word boundary only**
  (review round 3, finding 7 - live evidence below): the changed token's text must start with
  whitespace, or it must be the first token after a marker (already a boundary by construction). A
  continuation token - no leading whitespace - stays in the open segment regardless of what
  speaker/language it itself carries; the segment's own `speaker`/`lang` stay exactly as its first
  token locked them, never re-inferred from a later continuation. **Live evidence:** the owner's first
  option-C session showed a segment "Người nói B" whose source was just the single letter "B",
  immediately followed by a segment "Người nói A" reading "ạn nghề gì?" ("What is your job?") - two
  subword tokens of one word, "Bạn", with Soniox's diarization flipping the reported speaker between
  them. The old rule cut on ANY final-token speaker/language change, with no word-boundary check at
  all; see `SonioxJoinEngineTests`'s `test_finalTokenWithNoLeadingWhitespace...` tests, red against the
  pre-fix code with these exact tokens. The check is `Character.isWhitespace` on the token's first
  character - true for a leading space or newline (own test:
  `test_finalTokenStartingWithANewlineIsTreatedAsAWordBoundary`), false for leading punctuation with
  no space before it, which is therefore a continuation like any other (own test:
  `test_finalTokenStartingWithPunctuationButNoLeadingWhitespaceNeverCutsANewSegment`) - review round 5,
  finding 10. **Limit:** this only detects a boundary via whitespace, so a language written without
  spaces between words (e.g. Chinese, Japanese, Thai) can never be cut mid-utterance by this rule at
  all - every token in such a language lacks leading whitespace, so a speaker/language change can only
  ever end up on screen at the next marker (`<end>`/`<fin>`), never before it. Not exercised live: the
  app's only configured languages (`vi`/`en`) both use spaces.
- `speaker`: raw Soniox speaker ids mapped to "A", "B", "C", ... in order of first appearance within
  the current M connection - never derived from language. Missing -> `nil` -> "Chưa xác định". The
  map is per-connection: an M reconnect clears it (never resets the letter counter).
- `lang`: `nil` until the first original token is final, then locked.
- `source`: final original tokens plus the current non-final tail.
- `target`, `lang != me`: M's own translation chunk, set when final - unchanged from option B.
- `target`, `lang == me`: from on-device translation, once final and non-blank - see "Device
  translation" above. `nil` while queued/in-flight, `nil` forever once abandoned.
- `isFinal`: on `<end>` or `<fin>`.
- `startedAt`: `start_ms` of the first original token.
- `overlap`: always `false` (no live signal exists; see above).

## Limits

- Cost is a single stream ($0.12/h), including paused time under the keepalive page's billing
  statement (to be confirmed - see Live measurements above) - half of option B's.
- A `me`-language segment loses its translation, rather than showing a wrong one, whenever the
  device reports the language pair unavailable, or the `translate` call itself errors.
- One failure domain now: the dock's `reconnecting` covers the one socket only; on-device translation
  has none of its own beyond the per-segment abandon-on-error rule above.
- The `guest_japanese` demo scenario is now reproducible in shape but its wording is prototype-only.

## Unknowns (live session required)

| Unknown | Until confirmed |
|---|---|
| Whether the `.translationTask` closure and its `for await` loop survive the app backgrounding without re-running (which would matter for fatalError rule 4's re-run guard). | Assume it can re-run; `makeTranslationRequests()` already returns a fresh stream every call, so a re-run cannot double-consume. |
| Whether an in-flight `translate` call returns or throws cleanly when the app backgrounds or the task is cancelled mid-call. | Treated as any other error/termination - abandoned, never retried (rule 6/8). |
| ~~What `LanguageAvailability().status(from:to:)` actually returns on the owner's device~~ - confirmed live: `.installed`, and translation ran (see Live measurements above). The resolved-identifier log itself has not been read off the device yet. | Resolved. |
| Per-segment translation latency for a typical utterance length - unmeasured, so how quickly "Đang dịch…" resolves in practice is unknown. See "Live measurements" above for the five-sentence measurement plan. | No assumption made; the indicator is purely signal-driven (rule 7), never a timer, so latency does not affect correctness, only how long it visibly shows. |
| What the system's own download-progress sheet (Setup's `.supported` path) actually looks like - only reachable after deleting the vi/en language packs on a real device, never seen. | The app cannot restyle it either way; `SetupView` only records that the check ran and continues once it settles. |
| One-way on speech already in the target language: `translation_status: "none"` is inferred from the docs' two-way example and an observed symptom, never read directly off the wire. | Treat `translation_status: "none"` as original (untranslated) speech, including for `<end>`/`<fin>` markers; log the raw string once a live session can confirm it (`SonioxStreamSocket`'s one-shot diagnostic, unchanged). |
| Does the server ack the config before the first result? | listening on send; errors move state. |
| Does a zero-length URLSession message reach the server as the "empty frame"? | finalize, `<fin>`, empty frame, close on timeout. |
| Does a Read-only key pass `/v1/models` but fail the socket with 403? | Treat 403 like 401. |
| Owner's project and organization concurrency limit. | Read at key entry; only 1 connection is now required. |
| Is keepalive-only time billed? | Assume yes; confirm in Live measurements above. |
| Does `speaker` ever go missing with diarization on? | Keep `nil` reachable. |
| The live `/v1/models` response has not been observed yet against a real key since the target-check was dropped. | If `stt-rt-v5` is ever absent from it, the app reports the key as unusable; it never silently falls back to another model. |
| What an `one_way_translation` value other than `"all_languages"` (or absent) means, when `translation_targets` might also be empty. | Treat `translation_targets` as the sole authority for `me`'s own coverage in that case; never guess meaning into another `one_way_translation` value. |
