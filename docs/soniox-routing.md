# Soniox routing and stream contract

Decided 2026-09-22 against the public Soniox docs and the soniox-js SDK source of that date, then
amended by the project owner the same day (see the no-guess join rule below, which replaces the
original draft's join behaviour). Model: `stt-rt-v5`. Two live sessions have since run and found real
bugs, fixed and recorded in place below (the Unknowns table, the no-guess join's "Complete" rule, and
Key validation); what those two sessions have not yet exercised - most of Settings, other display
styles, real audio hardware edge cases - is still what the Unknowns section tracks.

## Decision

Two `one_way` streams per session over the same captured audio, identical config apart from
`translation.target_language`:

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

Stream M has `target_language = me`. Stream T has `target_language = target`.

- M is the only source of segments: text, language, speaker labels, `<end>` boundaries, and the
  translation of every segment whose language is not `me`.
- T contributes exactly one thing: the translation into `target` of M-segments whose language is
  `me`, and only when the no-guess join below accepts it. T's original text, labels and boundaries
  are never shown.
- HANDOFF.md section 4 rule, now real: language == `me` shows T's translation (via the join); any
  other language shows M's translation. `guest` is a recognition hint only.
- Translation tokens for a segment already in the direction's target language are discarded on both
  streams (see Unknowns).

Why not one `two_way(me, target)`: with the defaults (vi / auto / en) any guest who does not speak
English is transcribed and never translated. The API has no per-segment target and no
text-translation endpoint for a second pass.
Why not `two_way(me, guest)`: repurposes `target`, and fails when guest is `auto`.
Fallback, reconsidered only if a live session shows the two-stream join cannot work: `one_way(me)`
plus Apple's on-device Translation framework for me-to-target. One stream and no join, but iOS 18
minimum, a language-pack download prompt, a second engine, and Vietnamese support unverified.

## Audio origin (required for the join)

Buffer captured audio until both sockets have accepted their config, then send the identical byte
stream from byte zero to both. Both `start_ms` timelines then share one origin. Never let one
stream start ahead of the other.

## Stream contract (from docs)

- `wss://stt-rt.soniox.com/transcribe-websocket`. Config as first text frame, audio as binary
  frames at real-time pace or faster (408 otherwise), control frames `{"type":"keepalive"}` and
  `{"type":"finalize"}`, empty frame to end.
- Response: `tokens[]`, `final_audio_proc_ms`, `total_audio_proc_ms`, `finished` on the last
  message. Errors: message with `error_code`, `error_type`, `error_message`, `request_id`.
- Token: `text`, `is_final`, `confidence`, `start_ms`/`end_ms` (spoken tokens only), `speaker`
  (string number), `language`, `source_language` (translated tokens only), `translation_status` in
  `none | original | translation`.
- Non-final tokens are replaced in full on every response. Final tokens arrive once.
- Marker tokens `<end>` and `<fin>` are final and are stripped from text. Not documented as reliably
  tagged `.original`/`.none`, and never logged live to confirm either way - by inspection, the app's
  own dispatch would have appended one to translation text or silently dropped it depending on
  whichever status it happened to carry, so the app checks marker text before dispatching on
  `translation_status` at all, on both streams: a marker closes/resolves regardless of status and
  never becomes displayed or translated text.
- Tokens arrive in order: an original chunk, then its translation chunk for the same speaker (SDK
  source, not docs).
- Keepalive at least every 20 s when no audio flows; 5-10 s recommended. The keepalive page says a
  stream is charged for its full duration.
- 300 minutes per stream, fixed; 413 means reconnect. 401, 402, 403 are auth-class. 503 "cannot
  continue request" means restart with backoff. 429 means the project or organization concurrency
  cap (default 10 simultaneous connections per the limits page); `GET /v1/concurrency-limits`
  reports it.
- Endpoint detection reduces diarization accuracy (documented). Accepted.
- No overlap signal exists. "Nói chồng" is never rendered from a live session; the app still treats
  overlapping speech itself as an expected case, not an error (HANDOFF section 6, demo-data.json) -
  it just never claims a badge the service never sent.

## No-guess join (owner-decided, this is the contract the app implements)

A window-based join between two independently segmenting streams can attach the wrong speaker's
translation to a line: in the same time window, stream T is also translating the guest, and a
`start_ms`-only join can hand the guest's translation to the owner's `me`-language line. That is
worse than a missing translation, so the rule is: **whenever the app is not certain a T translation
belongs to exactly one `me` segment, it shows no translation for that segment - never a guessed one,
and never "Đang dịch…" once the app has given up on that window.**

For an M-segment with `lang == me` and window `[segment.startedAt, segmentEnd]` (`segmentEnd` is the
`end_ms` of the segment's last original token once the segment is final; while still open, the
window has no upper bound yet and the join simply keeps waiting):

### T chunks

Found by the project owner's second live session, against the code, not a live log of raw wire
values (Soniox never documents `translation_status` reliability and this app has never logged it):
attaching T's translation per raw token - even per final token - let a non-final wrong-language
original slip through uninspected, and let one response's `final_audio_proc_ms` cut a translation
off mid-way. Both are fixed by modelling T's own stream explicitly, as a sequence of **chunks**,
each the wire's own "original chunk, then its translation chunk" (SDK source, not docs):

- A chunk collects every **original** token (`.original`/`.none`, final or non-final alike) it sees,
  in arrival order, until the first **translation** token arrives - that begins the chunk's
  translation run, which collects every translation token (final or non-final) until either of the
  two completion triggers below fires.
- **Completion** - a chunk ends the instant either happens: another original token arrives (any
  finality - not just final ones) once its own translation run has begun, which also starts the next
  chunk; or a marker (`<end>`/`<fin>`) arrives, which starts no chunk. Neither trigger waits for
  finality.
- `.unrecognized` tokens take no part in a chunk.

**Certainty test** - both must hold for a completed chunk to attach to a window:
1. Every one of the chunk's original tokens - final and non-final alike, checked the instant each is
   seen, not deferred to the chunk's completion - has `start_ms` inside that window and
   `language == me`. A single original token of any finality in any other language inside the window
   fails the window's join permanently, the moment it is seen; a chunk whose original tokens fall
   inside more than one window (T and M do not segment identically) attaches to neither - attaching
   to either would be guessing which part of it belongs there.
2. M itself saw no overlap in that window: no other M original token, from a different speaker or a
   different final language than this segment's locked `speaker`/`lang`, has a `start_ms` inside
   the window.

A chunk that qualifies has its final translation tokens (non-final text is never committed - no
karaoke reveal) concatenated, in arrival order, into the window's collected translation; a window can
receive more than one qualifying chunk this way, since T commonly segments the same M window's audio
more finely than M does. If either check fails, the join is **abandoned** for that segment: `target`
stays `nil` permanently, and the app stops showing "Đang dịch…" for it immediately - the segment
reads as translated-only-in-its-own-language-if-any, same as any other segment whose translation
never arrived.

**Complete** - the signal that decides when to actually fill a window's `target` (from whatever its
chunks collected) or abandon it (nothing collected): a later chunk's own completion moving on to a
different window or to none at all, or T's own `<end>`/`<fin>` - never `final_audio_proc_ms` catching
up to `segmentEnd`, which reflects T's own audio-processing watermark running ahead of its
translation generation, not translation completeness. A chunk still in progress when a window opens,
or a chunk that completed before any window existed to attach it to (its whole token sequence,
including whichever marker ended it) - an "early chunk" - is buffered and replayed as one unit,
in order, the moment a new window opens; a chunk that still matches nothing is buffered again.
Abandonment is final; a later T chunk for an already-resolved window never retroactively fills
`target`. A window with no resolving signal at all - no chunk of T's ever completes toward it, no
marker ever arrives - stays pending forever: shown as nothing (see "Đang dịch…" below), not guessed
into a false "abandoned" just because nothing has happened yet. `end`/`endImmediately` and a
reconnect all abandon every still-pending window explicitly, so this indefinite-pending state only
persists while a session is genuinely still listening.

### Acceptance

In any session (recorded or live) with overlapping speech where the owner speaks `me` and the guest
speaks a non-`me` language in an overlapping time window, no `me`-language segment may ever display
a translation that actually belongs to the guest's speech. An empty `target` on such a segment is
the correct, expected outcome, not a defect. "Đang dịch…" must never be shown for a segment whose
join has already been abandoned by the rule above.

## Live measurements

Placeholder for the owner's first live session: usage measured before and after a timed pause
(both streams stay open with keepalive during pause, so this checks whether idle keepalive time is
actually billed).

- Usage before pause:
- Pause duration:
- Usage after pause:
- Conclusion:

*(left empty; the owner fills this in after a live session)*

## Segment mapping (from stream M)

`Segment { id; speaker; lang; source; target; isFinal; startedAt; overlap }`

- `id`: app-assigned, increasing per session.
- Boundary: new segment on the first original token after `<end>`, or when a final original token
  changes `speaker` or `language` from the open segment's locked values.
- `speaker`: raw Soniox speaker ids are mapped to "A", "B", "C", ... in order of first appearance
  within the current M connection - not by the raw id's numeric value, since diarization is not
  guaranteed to hand "1" to whoever spoke first. Missing -> `nil` -> "Chưa xác định". Never derived
  from language. The map is per-connection: an M reconnect clears it (never resets the letter
  counter), so a post-reconnect raw id gets a letter never shown before, rather than risk falsely
  implying it is the same person as a pre-reconnect speaker. M reconnects on every drop, since both
  sockets always reconnect together (see Session lifecycle below).
- `lang`: `nil` until the first original token is final, then locked.
- `source`: final original tokens plus the current non-final tail.
- `target`, lang != `me`: M's translation chunk following the segment's original chunk, set when
  final.
- `target`, lang == `me`: from T, via the no-guess join above. `nil` while the join is still
  waiting, and `nil` forever once the join is abandoned.
- `isFinal`: on `<end>` or `<fin>`.
- `startedAt`: `start_ms` of the first original token.
- `overlap`: always `false` (no live signal exists; see above).
- "Đang dịch…" (`target` (lang == `me`), via the T-join): a live signal, not a timer, mirroring
  M-direct below - shown only while the segment is final, `target` is `nil`, the join has not been
  abandoned, and the chunk T is currently mid-way through translating still looks like it belongs to
  this window (checked the instant each of its original tokens is seen - see T chunks above); cleared
  the moment a later response carries no translation token for that chunk at all. This live check is
  necessarily a running guess about where the in-progress chunk is heading, unlike the stricter,
  whole-chunk check that decides where `target` itself actually lands - so it can flip off if the
  chunk turns out to straddle windows or hit a disqualifying token, exactly like M-direct's own
  flip-flop. Also cleared once T signals **Complete** above or once the join is abandoned by the
  certainty test - never on `final_audio_proc_ms` timing. A window with no live signal at all shows
  nothing, per AGENTS.md's activity-indicator rule; one with a live signal shows "Đang dịch…"
  regardless of whether that chunk ultimately lands. Never shown for a discarded same-language
  translation.
- "Đang dịch…" (`target` (lang != `me`), M-direct): reflects a live signal, not a timer. Non-final
  tokens are replaced in full on every M response, so "the latest response still carries a
  translation token for this segment" is itself the signal - shown while that holds, cleared
  (`translationInProgress = false`) the moment a later response has none at all for the segment M is
  currently tracking, whether or not any final chunk ever landed. This is a display flip only, never
  a permanent verdict: a still-later response bringing the (possibly final) chunk after all sets the
  signal true again, or lands `target` directly - a late final translation always lands cleanly, and
  the segment is never simultaneously `targetAbandoned` and translated. `targetAbandoned` for a
  non-`me` segment only ever comes from `startNewMSegment`'s "M moved on to a new segment with
  nothing landed" rule, or from a reconnect - both genuinely permanent, unlike a single quiet
  response.

## Session lifecycle

- connecting: open both sockets, send both configs, buffer audio until both accepted. listening
  once both are sent (see Unknowns). 401/402/403 on either -> authError, which wins at any point
  during the current session, including from a socket the app has already superseded by a
  reconnect - but not from a socket that belonged to a session that has already ended, and not
  after "Phiên mới" starts a new session reusing the same underlying object: a stale rejection from
  the old session must not resurrect it, or leak into the new one.
- listening: AVAudioEngine tap -> AVAudioConverter -> Int16 16 kHz mono -> same bytes to both
  sockets. Check `channelCount`/`sampleRate` before `installTapOnBus`.
- paused: stop audio, keepalive every 10 s on both. Streams stay open so labels survive resume -
  M's speaker numbering must not restart mid-session. Pause time may be billed (see Live
  measurements above).
- reconnecting: entered when either socket drops. Owner-decided (option B requires a shared origin,
  and a one-sided reconnect never restores one): the app closes BOTH sockets and reopens both
  together as a fresh pair, buffering captured audio and sending identical bytes from byte zero to
  both new sockets, exactly as at session start - never just the dropped one. Before the new pair
  even starts connecting: the M segment open at the moment of the drop is closed exactly like a
  genuine `<end>` would close it (otherwise it would keep absorbing post-reconnect tokens under its
  pre-drop label); every T-join window still in flight against the old origin is abandoned; and so is
  any non-`me` segment whose M-direct translation was already under way but not yet complete - M's
  old connection is gone too, so nothing is ever coming to finish it either. No "Đang dịch…" lingers
  for any of these. M's diarization is always a brand-new connection too (it is part of the pair), so
  its speaker numbering always restarts on any reconnect, not only when M itself was the one that
  dropped; post-drop raw ids get letters never shown pre-drop (see Segment mapping above) rather than
  being displayed as the same person, since the app has no way to know a post-drop "1" is the same
  person as any pre-drop speaker. The mic keeps capturing throughout - only the network side is
  affected; captured audio keeps being buffered while reconnecting (see below).

  Every socket the app opens is tagged with the connection attempt ("generation") that created it.
  The moment either socket in the current pair closes, that generation is retired immediately -
  before anything else runs - so a second close from the SAME pair (its other socket detecting the
  same drop moments later) is recognised as stale and does not schedule a second, overlapping retry;
  exactly one retry is ever pending per outage. If a replacement pair itself fails before its config
  is sent, the app closes it and schedules exactly one more retry the same way - this is what lets
  retry actually converge across a multi-attempt outage, not just recover from a single clean drop.
  Backoff is exponential: 1 s, 2 s, 4 s, ... capped at 30 s, reset to 1 s the moment a pair fully
  connects again (HANDOFF section 6: "retry backoff"). Ending the session (`endImmediately` for a
  401/402/403, `end` otherwise) at any point during a reconnect stops the retry loop, including
  mid-backoff; a scheduled retry checks this again right before it actually fires. Reconnect
  completes before the 300-minute cap.

  Auth rejection is tracked separately from the per-attempt generation above, by a session-level
  counter that only changes when a genuinely new session starts (`start`) or the current one ends
  (`prepareToEnd`) - not on every reconnect attempt. This is what lets an auth rejection win across a
  session's own reconnect attempts while still being ignored once that session has ended, and
  prevents it leaking into a later session that reuses the same underlying object.

  Captured audio keeps arriving from a mic that never stops during a reconnect; it is buffered and
  sent from byte zero to whichever pair finally connects, across the WHOLE outage - a failed
  attempt in the middle does not discard what was captured so far, only a successful flush (or
  ending the session) ever clears it, so a later, separate outage starts from nothing. The buffer is
  bounded by an exact duration of the converted 16 kHz mono Int16 stream (32,000 bytes/s) - 60 s
  (1,920,000 bytes) - independent of whatever sample rate the device's microphone hardware happens
  to be capturing at, since a chunk-count bound would not have that property (each hardware tap
  callback's own duration varies with the hardware's rate). Beyond 60 s, the OLDEST buffered audio is
  dropped to make room for new - that audio is lost for both streams, same as any other gap a
  reconnect's timeline restart already creates. **Live session TODO:** confirm the actual buffered
  duration achieved on a real device before relying on the 60 s figure.
- ended: `finalize` on both, wait for `<fin>`, empty frame, wait for `finished`, close; close on
  timeout.

## Known UI deviations from HANDOFF

- **Auth-error banner action.** HANDOFF section 2.2 specifies "lỗi xác thực (→ Mở Cài đặt)" - opening
  the app's own Settings screen. Settings does not exist in this outcome, so the banner's button
  ("Nhập lại khóa") returns to Setup instead - the only in-app place a key can be re-entered - and
  Setup's own key field starts empty, since the rejected key is deleted from Keychain the moment the
  button is tapped. Owner-approved temporary deviation, to be rewired to open Settings once it
  exists.

## Key validation and language list

`GET https://api.soniox.com/v1/models` with `Authorization: Bearer <key>`. 401 -> key rejected.
200 -> decode only what this app uses from the `stt-rt-v5` entry: `languages` (array of
`{code, name}` objects - the guest picker, and the me/target/guest support check, matched by
`code`), `one_way_translation` (a string; the docs' own wording: "When contains string
'all_languages', any language from languages can be used"), and `translation_targets` (array of
`{target_language, source_languages, exclude_source_languages}` objects - the docs' own wording:
"List of supported one-way translation targets. If list is empty, check for one_way_translation
field"). A language is a usable one-way translation target when
`one_way_translation == "all_languages"`, or else when it appears as a `target_language` in
`translation_targets`. The key/model is usable when the `stt-rt-v5` entry exists, its `languages`
codes include `me` and `target`, plus `guest` when `guest` is a specific (non-auto) language, and
both `me` and `target` pass the one-way-translation check above. Then `GET /v1/concurrency-limits`;
a project limit below 2 is reported before any session starts. No metering is documented for either
call. Keys stay in Keychain only.

Found by the project owner's first live key check, on a real key that should have passed: this
section previously described `languages` as an array of strings (it is actually an array of
`{code, name}` objects, so decoding it as `[String]` silently failed) and checked
`translation_targets` alone (ignoring the `one_way_translation == "all_languages"` shortcut the
docs document) - together these reported a working key as unusable. Corrected against the live
https://soniox.com/docs/api-reference/stt/get_models page's embedded JSON example and field
descriptions, not the page's prose summary alone.

Owner-approved: a live session uses the fixed `me = vi`, `guest = auto`, `target = en` default until
Settings exists to change them (`LiveLanguageConfig.default`); not an open question.

## Limits

- Cost is 2x a single stream ($0.24/h vs $0.12/h), including paused time under the keepalive page's
  billing statement (to be confirmed - see Live measurements above).
- A `me`-language segment loses its translation, rather than showing a wrong one, whenever the
  no-guess join above cannot certify it - most often under overlapping speech.
- Two failure domains: the dock's `reconnecting` covers either socket.
- The `guest_japanese` demo scenario is now reproducible in shape but its wording is prototype-only.

## Unknowns (live session required)

| Unknown | Until confirmed |
|---|---|
| One-way on speech already in the target language: the app's first live session showed `me`-language speech simply never appearing at all - the app was silently dropping every token whose `translation_status` was `"none"`, treating it the same as an unrecognised value, instead of building segments from it like `.original`. Fixed. Still unconfirmed: the exact wire string was never logged during that session, so `"none"` is inferred from the docs' two-way example and the observed symptom, not read directly off the wire. | Treat `translation_status: "none"` as original (untranslated) speech on both streams, including for `<end>`/`<fin>` markers; log the raw string once a live session can confirm it. |
| Are original tokens and `<end>` timing identical across two streams on the same audio? | Join by time window and language only; never by text. |
| Do translation tokens carry `speaker`? Can a translation chunk arrive after the next `<end>`? | Attribute by the preceding original chunk; log shape/ordering only, never token text. |
| Does the server ack the config before the first result? | listening on send; errors move state. |
| Does a zero-length URLSession message reach the server as the "empty frame"? | finalize, `<fin>`, empty frame, close on timeout. |
| Does a Read-only key pass `/v1/models` but fail the socket with 403? | Treat 403 like 401. |
| Owner's project and organization concurrency limits. | Read them at key entry. |
| Is keepalive-only time billed? | Assume yes, on both streams; confirm in Live measurements above. |
| Does `speaker` ever go missing with diarization on? | Keep `nil` reachable. |
| The live `/v1/models` response has not been observed yet against a real key. | If `stt-rt-v5` is ever absent from it, the app reports the key as unusable; it never silently falls back to another model. |
| What an `one_way_translation` value other than `"all_languages"` (or absent) means, when `translation_targets` might also be empty. | Treat `translation_targets` as the sole authority for a specific target in that case; never guess meaning into another `one_way_translation` value. |
