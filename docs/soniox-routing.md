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
  String)>`, and `reportTranslationStarted(id:)`/`reportTranslationSuccess(id:target:)`/
  `reportTranslationFailure(id:)`.
- `LiveSessionController` forwards these to `SonioxLiveSession`, which owns `MeTranslationQueue` (the
  FIFO queue itself - no `TranslationSession` anywhere in it) and `SonioxJoinEngine` (which still owns
  `segments`, including a `me`-language segment's `target`/`translationInProgress`/`targetAbandoned`,
  via `applyTranslationStarted`/`applyTranslationSuccess`/`applyTranslationFailure`).
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

### The eight fatalError rules (owner-confirmed against Apple's docs)

Apple: "The system throws a fatalError if you use a [session] instance after the attached view
disappears or if you use it after changing the configuration." Checked by file:line in every
handoff:

1. `TranslationSession` appears only as the `.translationTask` closure parameter - never assigned to
   a property, captured by a stored closure, or passed out of the closure. Every `translate` call is
   made inside that closure.
2. `TranslationSession.Configuration` is created once per controller, then never reassigned,
   `invalidate()`-ed, or set back to `nil`. The language pair never changes mid-session (HANDOFF
   section 4 already forbids changing `me`/`target` mid-session).
3. `.translationTask` is attached to the root `ZStack` of `ConversationView.body` - the one view that
   lives for the whole conversation (`RootView`'s `.liveConversation` case; sheets only ever cover
   it, never replace it). Never attached in `RootView`. The configuration comes from the controller
   through `SessionControlling`, and is `nil` in demo, so the demo closure never runs.
4. `makeTranslationRequests()` returns a fresh `AsyncStream` every call, so a re-run of the closure
   (should SwiftUI ever re-invoke it) never double-consumes a stream still wired to a previous run.
5. Inside the closure, `translate` calls are sequential - at most one is ever awaited at a time (a
   plain `for await` loop, no child `Task` spawned per request).
6. Every `catch` in the closure, and the stream's own `onTermination` (the view disappearing, or the
   task being cancelled), marks the affected queued/in-flight ids abandoned and clears "Đang dịch…".
7. "Đang dịch…" for a `me` segment is true only from the moment the closure actually calls
   `translate` for that id (`reportTranslationStarted`) until it returns or throws - being merely
   queued does not count (AGENTS.md's activity-indicator invariant).
8. `me != target` is enforced before the configuration is created. Empty/whitespace-only source is
   never sent. Every error means "no translation" - never retried automatically.

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

## Banner when vi -> en is unavailable (owner decision)

Shown with the existing banner style (HANDOFF 2.2's "info" variant), lowest priority among
`ConversationView`'s banners (mic-denied, auth-error and network-lost all take precedence). Text,
verbatim: **"Lời của Bạn sẽ không được dịch sang tiếng Anh trên máy này."** Visible only from the
live session-start availability check through the rest of that session, and never in demo
(`DemoSessionController.showsTranslationUnavailableBanner` is always `false`).

## `target` mapping and "Đang dịch…" (from `Segment`)

- `lang != me`: unchanged from option B - M's own translation chunk following the segment's original
  chunk, set when final. "Đang dịch…" reflects a live M-direct signal exactly as before.
- `lang == me`: `target` is `nil` until the on-device queue's `reportTranslationSuccess` lands it,
  `nil` forever once `reportTranslationFailure`/an abandon lands (`targetAbandoned = true`).
  "Đang dịch…" (`translationInProgress`) is true only between `reportTranslationStarted` and
  whichever of success/failure/abandon follows - never while merely queued (fatalError rule 7).

## Session lifecycle (single socket)

Unchanged from option B for everything M itself does: connecting, listening, paused (keepalive every
10 s), reconnecting (exponential backoff 1 s/2 s/4 s/…/30 s, one retry per outage, the open segment
at the moment of a drop closed like a genuine `<end>`, speaker letters reset), ended (`finalize`,
`<fin>`, empty frame, close on timeout). What changed: there is exactly one socket, so reconnect no
longer needs a shared-audio-origin requirement between two sockets, and the audio buffer (60 s of
16 kHz mono Int16, oldest dropped beyond that) is simpler - it just waits for the one socket's config
to be accepted, not two.

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

Not yet measured (unchanged from option B: two live sessions have run, neither paused long enough
with the Soniox Console open before and after to read this off). The next live session that includes
a pause should read, from the Soniox Console (whichever usage unit it displays - minutes or dollars):

- Usage before pause:
- Pause duration:
- Usage after pause:
- Conclusion: whether the Console's usage figure moved by roughly the pause duration for this now
  single stream (it stays open with keepalive during pause per Session lifecycle above, so a mover
  confirms the keepalive page's billing statement; no movement would contradict it and needs its own
  follow-up).

## Segment mapping (from stream M)

`Segment { id; speaker; lang; source; target; isFinal; startedAt; overlap; targetAbandoned;
translationInProgress }`

- `id`: app-assigned, increasing per session (per `SonioxJoinEngine` instance - resets on "Phiên
  mới", unlike the translation-request counter above, which does not).
- Boundary: new segment on the first original token after `<end>`, or when a final original token
  changes `speaker` or `language` from the open segment's locked values.
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
| What `LanguageAvailability().status(from:to:)` actually returns on the owner's device for the resolved `vi`/`en-US` identifiers - `.installed` is assumed since both are reportedly already downloaded, but never logged live. | The one-shot resolved-identifier log (`TranslationLanguages.swift`) is what a live session should read to confirm. |
| Per-segment translation latency for a typical utterance length - unmeasured, so how quickly "Đang dịch…" resolves in practice is unknown. | No assumption made; the indicator is purely signal-driven (rule 7), never a timer, so latency does not affect correctness, only how long it visibly shows. |
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
