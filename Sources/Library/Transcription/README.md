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

`TranscriptRunner.run(engine:)` walks the episode in `windowSeconds` chunks from 0 to the
end, whichever recogniser was asked for, regardless of what playback is doing. Pressing the
running recogniser's button stops it; pressing the other swaps to it.

**Nothing on disk changes until the pass finishes.** Windows accumulate in memory and are
merged into the store in one go at the end, so re-transcribing an episode that already has
a transcript leaves the old one whole and readable until the new one is ready. The
tradeoff is deliberate and one-sided: a pass abandoned halfway — cancelled, failed, app
killed — is thrown away rather than half-applied.

Partial results from the recognizer are ignored. Live text meant lines rewriting
themselves under the reader while the page flickered, and the same audio recognised
several times over as the playhead moved; a percentage says as much and costs nothing.

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
