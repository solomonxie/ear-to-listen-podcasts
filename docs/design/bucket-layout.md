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

## Not sidecars: the app's own data

Playlists, hand edits, topics, bookmarks and transcript corrections already
travel as one library snapshot (`Sources/Backup/`, "Auto sync app data to this
bucket"). A per-episode `.json` would be a second source of truth for the same
rows, and a merge problem as soon as the two disagree.

The split: **the snapshot owns app data; sidecars own only what's worth another
tool being able to read.** Today that's the transcript.
