# Soniox routing and stream contract

Decided 2026-09-22 against the public Soniox docs and the soniox-js SDK source of that date, then
amended by the project owner the same day (see the no-guess join rule below, which replaces the
original draft's join behaviour). Model: `stt-rt-v5`. Nothing here is proven live yet; the Unknowns
section lists what a live run must confirm before the matching app behaviour is treated as settled.

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
- Marker tokens `<end>` and `<fin>` are final and are stripped from text.
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

**Certainty test** - all three must hold for the join to be accepted:
1. Every T original token whose `start_ms` falls inside the window has `language == me`. A single
   T original token in any other language inside the window fails the test permanently.
2. M itself saw no overlap in that window: no other M original token, from a different speaker or a
   different final language than this segment's locked `speaker`/`lang`, has a `start_ms` inside
   the window.
3. The T translation chunks that follow the qualifying T original tokens are contiguous in time (no
   T original chunk in a different language interrupts them inside the window); they are
   concatenated in time order into the segment's `target`.

If the test fails, or if T's `final_audio_proc_ms` has passed `segmentEnd` without ever satisfying
check 1 or check 2, the join is **abandoned** for that segment: `target` stays `nil` permanently,
and the app stops showing "Đang dịch…" for it immediately - the segment reads as translated-only-in-
its-own-language-if-any, same as any other segment whose translation never arrived. Abandonment is
final; a later T token for the same window never retroactively fills `target`.

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
- `speaker`: first original token's `speaker`; "1" -> "A", "2" -> "B", "3" -> "C" in label order.
  Missing -> `nil` -> "Chưa xác định". Never derived from language.
- `lang`: `nil` until the first original token is final, then locked.
- `source`: final original tokens plus the current non-final tail.
- `target`, lang != `me`: M's translation chunk following the segment's original chunk, set when
  final.
- `target`, lang == `me`: from T, via the no-guess join above. `nil` while the join is still
  waiting, and `nil` forever once the join is abandoned.
- `isFinal`: on `<end>` or `<fin>`.
- `startedAt`: `start_ms` of the first original token.
- `overlap`: always `false` (no live signal exists; see above).
- "Đang dịch…": shown only while the segment is final, `target` is `nil`, and the contributing
  stream still has non-final tokens for that window and the join has not been abandoned. Cleared
  with no translation once that stream's `final_audio_proc_ms` has passed the segment's `end_ms`
  and its next original chunk has begun, or once the join is abandoned by the certainty test.
  Never shown for a discarded same-language translation.

## Session lifecycle

- connecting: open both sockets, send both configs, buffer audio until both accepted. listening
  once both are sent (see Unknowns). 401/402/403 on either -> authError.
- listening: AVAudioEngine tap -> AVAudioConverter -> Int16 16 kHz mono -> same bytes to both
  sockets. Check `channelCount`/`sampleRate` before `installTapOnBus`.
- paused: stop audio, keepalive every 10 s on both. Streams stay open so labels survive resume -
  M's speaker numbering must not restart mid-session. Pause time may be billed (see Live
  measurements above).
- reconnecting: entered when either socket drops. Reopen that socket with its config; its timeline
  restarts, so the join for M-segments started before T's drop is abandoned (they stay `nil`). If M
  drops, its speaker numbering restarts and labels before and after are not comparable. Reconnect
  both before the 300-minute cap.
- ended: `finalize` on both, wait for `<fin>`, empty frame, wait for `finished`, close; close on
  timeout.

## Key validation and language list

`GET https://api.soniox.com/v1/models` with `Authorization: Bearer <key>`. 401 -> key rejected.
200 -> the `stt-rt-v5` entry supplies `languages` (guest picker) and
`one_way_translation`/`translation_targets` (me and target pickers). Then
`GET /v1/concurrency-limits`; a project limit below 2 is reported before any session starts. No
metering is documented for either call. Keys stay in Keychain only.

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
| One-way on speech already in the target language: skipped, echoed, or translated? | Discard same-language translation tokens; no placeholder. |
| Are original tokens and `<end>` timing identical across two streams on the same audio? | Join by time window and language only; never by text. |
| Do translation tokens carry `speaker`? Can a translation chunk arrive after the next `<end>`? | Attribute by the preceding original chunk; log shape/ordering only, never token text. |
| Does the server ack the config before the first result? | listening on send; errors move state. |
| Does a zero-length URLSession message reach the server as the "empty frame"? | finalize, `<fin>`, empty frame, close on timeout. |
| Does a Read-only key pass `/v1/models` but fail the socket with 403? | Treat 403 like 401. |
| Owner's project and organization concurrency limits. | Read them at key entry. |
| Is keepalive-only time billed? | Assume yes, on both streams; confirm in Live measurements above. |
| Does `speaker` ever go missing with diarization on? | Keep `nil` reachable. |
