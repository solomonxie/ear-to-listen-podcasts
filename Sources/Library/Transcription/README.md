# Transcription

Turns an episode's audio into timestamped lines: one whole-episode pass, front to back, in
the background, with a percentage while it runs and the text all at once when it's done.

## Sidecar transcripts

**Convention: same basename as the audio, different extension.** `shows/ep1.mp3` →
`shows/ep1.vtt`. Nothing else is inspected — no manifest, no naming scheme, no index.

Sidecar extensions are absent from `audioExtensions` (`Sources/Library/Sync.swift:7`), so
they never sync as tracks.

### Reading — liberal

Tried in this order, first one that parses wins:

| ext | notes |
|---|---|
| `.vtt` | WebVTT. Canonical: the only common format with an **end** time per line. |
| `.srt` | SubRip. Start+end, comma decimals, leading sequence numbers. |
| `.json` | Podcast Index transcript. Speaker names are prefixed into the text. |
| `.lrc` | Lyrics. Start times only — ends are backfilled from the next line. |
| `.txt` | No timings. Sentences are spread across the episode by length; readable and searchable, **not** accurate enough to seek by. |

Tolerated: CRLF, a BOM, cue identifiers, cue settings (`align:start`), multi-timestamp LRC
lines (`[00:10.00][00:30.00]chorus`), LRC header tags (`[ti:]`/`[ar:]`), and per-word
timings in both enhanced-LRC (`<00:12.30>`) and VTT (`<00:00:12.300>`) form — stripped,
not left in the text.

A sidecar is imported **only when nothing is stored locally**. It never overwrites work
done in the app, least of all corrections.

### Writing — strict

`.vtt` (read back) plus `.lrc` (courtesy copy for lyrics-aware players), both next to the
audio, on any provider whose `isWritable` is true. Written after a correction immediately,
and at the end of a pass otherwise — not per window.

**Why VTT is canonical.** `TranscriptCoverage` decides what still needs transcribing from
segment *spans*, and the empty segments `TranscriptRunner.padded` writes are how "this
stretch was listened to and nobody spoke" is remembered. LRC has no end times and no way
to say that, so a transcript round-tripped through LRC alone would re-transcribe its own
silences forever. Our extras ride in `NOTE` blocks, which other players ignore:

```
WEBVTT

NOTE byop engine=onDevice

00:00:04.120 --> 00:00:08.900
Welcome back to the show.

NOTE byop silence 00:00:08.900 --> 00:02:00.000

NOTE byop edited

00:02:00.000 --> 00:02:04.000
I'm here with Dr Huberman.
```

## Running a pass

`TranscriptRunner.run(engine:)` walks the episode in `windowSeconds` chunks, whichever
recogniser was asked for, regardless of what playback is doing. Pressing the running
recogniser's button stops it; pressing the other swaps to it.

**Only the stretches with nothing in them yet** — the plan comes from
`TranscriptCoverage.windows`, not from 0 to the end — and **each window is stored the
moment it lands**. So an interrupted pass costs the window in flight and nothing else, and
resuming picks up at the first hole.

Stored is not shown: `frozenLines` holds the page at the transcript the pass started from
and releases it when the pass ends, so the finished transcript arrives in one piece
instead of the page rewriting itself line by line under the reader. A pass that stops
early releases it too — with nothing working on the episode, a part-finished transcript is
the truth about it. Holding the whole pass in memory until the last
window read better on paper and threw away an hour of recognition every time the app was
switched away from.

A pass keeps a `UIApplication` background assertion while it runs, so the window in flight
can land after the app is put away, and `resumeIfInterrupted()` on the next foreground
picks up a pass the system stopped. The listener pressing Stop clears that; nothing else
does.

**A window that comes back with no words is held, not stored.** Silence is recorded as
covered and never looked at again, and a recognizer that has quietly stopped working
returns exactly what a silent stretch does — so quiet windows are buffered and only
written once a later window proves the recognizer is working, or the pass reaches the end.
Six quiet windows in a row ends the pass with an error instead, leaving that audio
untranscribed so it gets another try.

Each window has an inactivity watchdog rather than one deadline from the start: the clock
is reset by every revision the recognizer reports, so a long window that's working is left
alone while a stuck one (the usual cause: the app suspended out from under it) gives up in
a minute.

Partial results from the recognizer are ignored. Live text meant lines rewriting
themselves under the reader while the page flickered, and the same audio recognised
several times over as the playhead moved; a percentage says as much and costs nothing.

## What the recognizer actually hands over

Two things about `SFSpeechRecognizer` that the shape of the output depends on:

**A hypothesis with no timestamps.** It routinely returns one where every `timestamp` is
zero and only `duration` is set. Counting a single non-zero duration as "timed" put that
whole hypothesis on the window's first instant, folded in beside the properly timed
hypothesis of the same audio — so every sentence appeared twice, once at the top of the
window and once where it was said. `hasTimings` now asks whether anything past the first
word *moves*, and `absorbing` drops a run it hears again rather than leaving a copy behind
at the old timestamp.

**One token at a time, whatever the language.** Joining with a space is right for English
and wrong for Chinese, Japanese and Korean — it turns a sentence into loose characters with
gaps down the middle of every word. `TranscriptLines.joined` drops the space only between
two such tokens, so a Latin word inside a Chinese sentence keeps its air.

`supportsOnDeviceRecognition` is read but not obeyed. It is a false negative often enough
— phones with the language's dictation model installed still report `false` — that
refusing on it alone means refusing audio the phone can handle. The attempt runs anyway,
and only a failed attempt is reported as a missing model. `OnDeviceLanguages` sweeps the
flag across every supported locale to mark the language picker, which is advisory.

## Layout

Platform-neutral (portable as-is): `TranscriptCoverage` (gaps, windows, abandon rule),
`TranscriptLines` (word grouping), `TranscriptFile` (parse and serialize),
`TranscriptSidecar`, `TranscriptRunner`, `TranscriptionEngine`.

Apple-specific: `AppleSpeechTranscriber` (`import Speech`), `OnDeviceLanguages`
(`import Speech`), `AudioWindowFile` (`import AVFoundation`). A port replaces these.
