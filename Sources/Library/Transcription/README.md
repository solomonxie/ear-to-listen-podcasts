# Transcription

Turns an episode's audio into timestamped lines, gap by gap, nearest the playhead first.

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
and after the fill loop settles otherwise — not per window.

**Why VTT is canonical.** `TranscriptCoverage` decides what still needs transcribing from
segment *spans*, and the empty segments `LiveTranscript.padded` writes are how "this
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

## Running the loop

Windows are only *started* while the episode is playing, unless "Keep going while paused"
is on — a window already in flight finishes either way, so pausing costs nothing. Default
is follow-playback: a paused episode shouldn't be spending battery or Whisper credit.

Partials are published at most once a second (`AppleSpeechTranscriber.partialInterval`).
The recognizer revises several times a second and rewrites its whole tail each time; at
that rate it reads as flicker, not as words arriving. A revision that makes out nothing is
also dropped rather than blanking the pane.

`supportsOnDeviceRecognition` is read but not obeyed. It is a false negative often enough
— phones with the language's dictation model installed still report `false` — that
refusing on it alone means refusing audio the phone can handle. The attempt runs anyway,
and only a failed attempt is reported as a missing model. `OnDeviceLanguages` sweeps the
flag across every supported locale to mark the language picker, which is advisory.

## Layout

Platform-neutral (portable as-is): `TranscriptCoverage` (gaps, windows, abandon rule),
`TranscriptLines` (word grouping, settled/volatile split), `TranscriptFile` (parse and
serialize), `TranscriptSidecar`, `LiveTranscript`, `TranscriptionEngine`.

Apple-specific: `AppleSpeechTranscriber` (`import Speech`), `OnDeviceLanguages`
(`import Speech`), `AudioWindowFile` (`import AVFoundation`). A port replaces these.
