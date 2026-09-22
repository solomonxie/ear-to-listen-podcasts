# How a bucket is laid out

What this app writes beside someone's audio, and why it's shaped that way. The
bucket is the listener's own — the layout has to stay readable to every other
tool they use, and has to work on a bucket this app has never touched.

## Decision: flat sidecars, matched on basename

```
renwuzhi/2026/ep-01.mp3          audio — never rewritten
renwuzhi/2026/ep-01.vtt          canonical transcript, the one read back
renwuzhi/2026/ep-01.lrc          for lyrics-aware players
renwuzhi/2026/ep-01.zh-CN.vtt    per-language, when there's more than one
renwuzhi/2026/ep-01.jpg          episode artwork
renwuzhi/2026/ep-02.mp3
…
```

`TranscriptFile.sidecarPath` writes it, `TranscriptSidecar.load` reads it, and
`RemoteFileGroup` folds it back up for the browser. Matching on basename is the
whole convention — the same one Plex, Jellyfin, Kodi and YouTube use, so a
transcript this app writes is picked up by tools that never heard of it.

## Rejected: embedding in the audio file

ID3 `USLT`/`SYLT`, MP4 timed-text tracks and Vorbis `LYRICS` can all carry a
transcript. On S3 they can't, because **objects are immutable** — changing a tag
re-uploads the whole object.

| | sidecar | embedded |
|---|---|---|
| One transcript correction | ~20 KB PUT | ~40 MB PUT |
| Worst case on a bad write | a broken text file | a corrupted episode |
| Effect on sync | none | `SyncEngine.hasChanged` compares contentHash, so every edit re-marks the episode changed and re-imports it |
| Two languages | two files | awkward to impossible |
| `.wav` | fine | nowhere to put it |

The sync row is the decisive one: writing tags would put the app in a fight with
its own change detection.

Reading embedded lyrics as one more fallback source is fine and costs nothing.
Writing them is not.

## Rejected: a folder per episode

`renwuzhi/2026/ep-01/{audio.mp3, transcript.vtt, cover.jpg}` puts everything
about an episode in one place, and loses on three counts:

- **It's lock-in.** It only works on a bucket in this app's layout. Migrating an
  existing one means a full copy per object — S3 has no rename — and the
  project's whole premise is reading buckets it didn't create.
- **The browser gets worse.** `RemoteBrowserView` lists one level at a time, so
  37 episodes become 37 folders to enter one at a time.
- **Other tools get worse.** Forty objects all named `audio.mp3` are miserable
  in the S3 console, in Finder, and in any other player. Today the filename
  carries the meaning.

## The cost of flat, and what pays it

A 37-episode folder holds ~150 objects, three-quarters of them sidecars. That
lands entirely on one screen — the library never sees them, since
`FileKind.isPlayable` filters at sync.

`RemoteFileGroup` folds sidecars into a caption under the episode they belong
to, so the browser lists 37 rows rather than ~150, and the caption answers a
question the flat listing couldn't:

```
▢ ep-01.mp3                    42 MB
    vtt · lrc · jpg                   ← each one opens its own preview
▢ ep-02.mp3                    41 MB
    vtt · zh-CN.vtt
▢ ep-03.mp3                    43 MB
    no transcript                     ← only shown when others here have one
```

Anything the grouping can't claim — a loose note, a bucket-level cover, this
app's own backup zip — keeps its own row. A bucket is the listener's, so nothing
in it is hidden.

## What the app writes into the audio's own folder

Only two things, and neither touches a file already there: a sidecar (a
different extension beside the episode) and an episode the listener uploaded
from Files, under a name nothing in the folder has. `CloudWrite` enforces the
split — `upload` refuses a playable extension, `uploadEpisode` requires one and
a free key.

## Not sidecars: the app's own data

Playlists, hand edits, topics, bookmarks and transcript corrections already
travel as one library snapshot (`Sources/Backup/`, "Auto sync app data to this
bucket"). A per-episode `.json` would be a second source of truth for the same
rows, and a merge problem as soon as the two disagree.

The split: **the snapshot owns app data; sidecars own only what's worth another
tool being able to read.** Today that's the transcript.

## When transcripts move, in each direction

**Up, automatically.** A finished pass writes `ep-01.vtt` (and `.lrc`) beside
the audio. A hand correction goes up immediately rather than waiting for a pass
to end — it's the one thing that can't be regenerated. Read-only buckets skip it
silently; a failed upload is reported but never interrupts playback, since the
text is safe locally and in the backup.

**Down, on two occasions only.** The sync listing already sees both `ep-01.mp3`
and `ep-01.vtt`, so it records the pairing on the track
(`Track.transcriptPath`, carried through the queue on `SyncJob.transcriptPath`).
That path is then read:

1. when you open an episode that has no transcript stored locally;
2. when you press a transcribe button — it asks the bucket before spending
   battery or an API call, since a file someone dropped there is both better and
   free compared to recognising two hours of speech again.

Nothing else pulls. An episode whose text is already here doesn't re-fetch on
every open — that would be a request per episode for a file that rarely changes.

```
 sync listing ──▶ ep-01.mp3 ✚ ep-01.vtt ──▶ Track.transcriptPath
                                                   │
 open episode, nothing stored ─────────────────────┤
 press transcribe ─────────────────────────────────┤──▶ fetch, merge
                                                   │
 nothing stored, no sidecar ──────────────────────▶ recognise on device
```

**A hand edit ends the conversation.** Once you've corrected a line, the episode's
text is yours: remote is never read again and the next export writes over it.
That does lose an edit made to the bucket afterwards — accepted deliberately,
because the correction on the phone is the thing that can't be reproduced.

Knowing the path also removes the probing: matching on basename meant asking for
`.vtt`, `.srt`, `.lrc`, `.json` and `.txt` in turn and being told "no" four or
five times per episode.
