# Sources Section

Embedded in the single-page root (`HomeView`), not a standalone tab. Backed by
the real `ProviderStore`/`SyncEngine` — `SourcesSectionView` lists every
`ProviderRecord` episodes can come from (shared `SettingsViewModel` with the
Settings section): a bucket in any of the five clouds, and a folder picked off
this device.

**Named "Sources", not "Remote".** A local folder is connected here on the same
terms as a bucket — listed, queued, synced, browsed, played — so the section
can't be named after where the files are.
Tapping a connection goes into `RemoteBrowserView` (no separate detail
screen), which recursively browses one directory level at a time. Every
level — root or subfolder — carries the exact same "More" menu (queue,
upload, delete) and a one-line stats footer scoped to that folder; there's no per-level
distinction, since sync controls/delete act on the connection as a whole
regardless of where you're browsing. Tapping a file plays it directly, same
as any other episode.

## When the network gets touched

Browsing doesn't. Both the folder listing and the stats footer are built
from already-synced rows (`TrackStore.directoryListing` /
`TrackStore.stats`), so opening a bucket costs nothing and works offline.
The provider is only listed:

- once, when the connection is added — `enqueueConnection` walks the whole
  bucket and queues every audio file that needs fetching;
- on an explicit "Sync Now";
- on a schedule, when that connection's `syncFrequencyMinutes` is set.

A connection left on "Manual" therefore never fetches file headers on its
own after that first import.

Multiple connections can point at the same bucket with different key
prefixes — each row shows a small gray `s3://bucket/prefix` subtitle so
they're told apart (`ProviderManager.displayPath`), in that cloud's own
scheme (`s3://`, `cos://`, `oss://`, `az://`, `gs://`), with its short name
(`S3`, `COS`, `OSS`, `Azure`, `GCS`) on the row's tile.

## Adding a connection

The ⊕ is a menu with two answers: a cloud bucket, or a folder on this device.

`AddCloudSourceView` — one screen for all five clouds, differing only in what
`CloudSourceKind` says each calls its credential and whether the region is
detected (AWS) or picked (COS, OSS) or not addressed at all (Azure, Google).
It validates the bucket/credentials, saves the
`ProviderRecord`, then calls `SyncQueueManager.enqueueConnection(providerID:)`
to queue the whole bucket (recursively) rather than running one opaque
background sync — so the new source's progress (and any per-file errors)
shows up in the sync queue right away instead of only once everything's done.

## A folder on this device

Picked straight from the ⊕ menu — no screen to fill in, since the folder *is*
the whole connection. The grant is kept as a security-scoped bookmark
(`LocalFilesProvider`), alongside the folder's path for the row's `files://…`
subtitle, and the pick queues the folder the same way saving a bucket does.

It differs from a bucket in exactly three places, all of them behind
`CloudProvider.isOnDevice`:

- the offline guards (`SyncEngine.sync`, `PlaybackEngine.loadAndPlay`) don't
  apply — the files are right here;
- the first play **copies** the episode into `Documents/Downloads` rather than
  downloading it (`AudioCache.store` takes a `file://` source), so what's in
  the library outlives the original being moved, renamed or deleted — the thing
  that made a read-in-place local source untrustworthy;
- app-data backup isn't offered to it: a folder on this phone is no place to
  keep a backup of this phone.

## Adding episodes

"Upload from Files" in the folder browser's More menu is the only way in.
Picking doesn't upload anything: `EpisodeUpload.queue` writes one `SyncJob` per
file, carrying a security-scoped bookmark and the key it's bound for in the
folder on screen. The drain loop sends it (`EpisodeUpload.send`, stage
`Uploading`) and then imports what it just put there, in the same job — so an
upload pauses, paces, retries and survives a relaunch like every other unit of
work here, and a 60 MB episode never holds the screen it was picked from. The
bookmark rather than a copy, so ten queued episodes aren't ten files on the disk
twice.

Uploading beats connecting the folder it came from when the episode should exist
anywhere but here: an episode in the bucket is backed up and on every device.

`CloudWrite` is what makes that safe. The rule was "never write audio"; it is
now "never write *over* audio", which is the rule it was always standing in for:
`upload` (sidecars, archives) refuses a playable extension, `uploadEpisode`
requires one and refuses a key that already exists. Both go through the one
per-provider `write`, so neither is a habit five backends have to remember. The
picker's names are deduped against the live listing first (`ep-01 2.mp3`), so
the existence check is the backstop for a folder that changed underneath it.

## Bucket layout

Transcripts and artwork sit flat beside the audio, matched on basename
(`ep-01.mp3` / `ep-01.vtt`), never embedded in the audio and never in a folder
per episode — `docs/design/bucket-layout.md` has the reasoning and the two
rejected alternatives. `RemoteFileGroup` folds the sidecars into a caption under
their episode, so a 37-episode folder lists 37 rows instead of ~150.

## Queue

Per-file jobs (`SyncJob`, in `syncJobs`) persist across launches. A job with an
`uploadBookmark` puts the file in the bucket first and imports it second; every
other job only imports.
`SyncQueueManager.drain()` claims jobs via `SyncJobStore.dequeueNextPending()`,
which fetches the oldest pending job and flips it to `.running` in the same
write transaction — that atomicity matters, since two concurrent drain slots
racing a plain fetch-then-mark-running could otherwise both grab the same
pending job and both try to insert the same track, tripping the
`idx_tracks_provider_path` unique constraint. Each claimed job runs
`SyncEngine.perform(_:providerRecord:)`, which wraps `importFileIfNeeded` and
closes the row either way. Failed jobs can be retried individually
(`SyncJobStore.retry`) rather than requiring a queue clear.

**Listing and importing are separate.** Every entry point — add-connection,
"Sync Now", the schedule — goes through `SyncQueueManager.sync(providerRecord:)`, which lists, queues what needs
fetching (new, changed, or previously lost; unchanged files get no row at all),
and returns. `drain()` is the only thing that imports, so a bucket of thousands
no longer holds a button hostage for minutes and the queue's speed control
applies to a whole-bucket pass like anything else.

A pass that hits the 100-job ceiling stops there and is remembered. When the
queue drains empty, those connections are re-listed and the next batch queued,
repeating until the bucket is done — so a large bucket finishes on its own
rather than needing a Sync Now per hundred files. Pausing stops both halves.

The queue is global across every source, not per-bucket. `SourcesSectionView`
shows a "Queue (N)" pill below the
connections list; each connection's own "More" menu also links straight to
`SyncQueueView` for the full list, pause/resume, speed, and clear controls
(all on the "Queue (N)" row itself, not a separate on/off toggle).

## Screen Composition

```
SourcesSectionView.swift (embedded in HomeView, not a tab)
┌─────────────────────────────────────────┐
│ "Sources" header + add menu             │──→ AddCloudSourceView sheet, or the
│                                         │    OS folder picker
│ ┌─────────────────────────────────────┐ │
│ │ RemoteSourceRow (label + path)       │ │──→ tap → RemoteBrowserView.swift
│ │   long-press → Delete                │ │──→ SettingsViewModel.delete(_:)
│ └─────────────────────────────────────┘ │
│ [ Queue (N) ] (pill button)             │──→ tap → SyncQueueView.swift
└─────────────────────────────────────────┘
        │
        ▼
RemoteBrowserView.swift (pushes itself per subfolder, same UI at every level)
┌─────────────────────────────────────────┐
│ Subfolders + files at this level         │──→ CloudProvider.listDirectory(atFolder:)
│   tap a file → import if needed, play    │──→ SyncEngine.importFileIfNeeded /
│                                          │     PlaybackEngine.play(track:)
│ One-line stats footer (this folder)      │──→ TrackStore.stats(forProvider:pathPrefix:)
│   + how to add episodes here             │
│ "More" toolbar menu:                     │
│   last synced, sync queue,               │──→ SyncQueueManager.sync(…) (queues,
│   upload from Files, delete              │     doesn't import) /
│                                          │     EpisodeUpload.run(_:avoiding:) /
│                                          │     SettingsViewModel.delete(_:)
└─────────────────────────────────────────┘
```
