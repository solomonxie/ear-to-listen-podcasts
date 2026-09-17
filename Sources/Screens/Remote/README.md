# Remote Section

Embedded in the single-page root (`HomeView`), not a standalone tab. Backed by
the real `ProviderStore`/`SyncEngine` — `RemoteSectionView` lists actual S3
`ProviderRecord`s (shared `SettingsViewModel` with the Settings section).
Tapping a connection goes into `RemoteBrowserView` (no separate detail
screen), which recursively browses one directory level at a time. Every
level — root or subfolder — carries the exact same "More" menu and a
one-line stats footer scoped to that folder; there's no per-level
distinction, since sync controls/delete act on the connection as a whole
regardless of where you're browsing. Tapping a file plays it directly, same
as any other episode.

## When the network gets touched

Browsing doesn't. Both the folder listing and the stats footer are built
from already-synced rows (`TrackStore.directoryListing` /
`TrackStore.stats`), so opening a bucket costs nothing and works offline.
The provider is only listed:

- once, when the connection is added — `enqueueConnection` walks the whole
  bucket and queues every audio file;
- on an explicit "Sync Now";
- on a schedule, when that connection's `syncFrequencyMinutes` is set.

A connection left on "Manual" therefore never fetches file headers on its
own after that first import.

Multiple connections can point at the same bucket with different key
prefixes — each row shows a small gray `s3://bucket/prefix` subtitle so
they're told apart (`ProviderManager.s3DisplayPath`).

## Adding a connection

`AddS3ProviderView` validates the bucket/credentials, saves the
`ProviderRecord`, then calls `SyncQueueManager.enqueueConnection(providerID:)`
to queue the whole bucket (recursively) rather than running one opaque
background sync — so the new source's progress (and any per-file errors)
shows up in the sync queue right away instead of only once everything's done.

## Queue

Per-file jobs (`SyncJob`, in `syncJobs`) persist across launches.
`SyncQueueManager.drain()` claims jobs via `SyncJobStore.dequeueNextPending()`,
which fetches the oldest pending job and flips it to `.running` in the same
write transaction — that atomicity matters, since two concurrent drain slots
racing a plain fetch-then-mark-running could otherwise both grab the same
pending job and both try to insert the same track, tripping the
`idx_tracks_provider_path` unique constraint. Each claimed job runs
`SyncEngine.importFileIfNeeded` — the same import path the whole-bucket
`SyncEngine.sync(providerRecord:)` uses. Failed jobs can be retried individually
(`SyncJobStore.retry`) rather than requiring a queue clear.

`sync(providerRecord:)` (manual "Sync Now", and the periodic background sync)
runs its own sequential pass rather than going through `drain()` — but for
every file that actually needs fetching (new, changed, or previously lost;
already-synced unchanged files are skipped with no row at all) it still opens
and closes a `SyncJob` row inline, posting `.syncQueueDidChange` so
`SyncQueueManager` refreshes. That's what puts a whole-bucket sync's files in
the same queue UI as a queued per-file import, instead of only the latter
being visible while it runs.

The queue is global across every source, not per-bucket. `RemoteSectionView`
shows a "Queue (N)" pill below the
connections list; each connection's own "More" menu also links straight to
`SyncQueueView` for the full list, pause/resume, speed, and clear controls
(all on the "Queue (N)" row itself, not a separate on/off toggle).

## Screen Composition

```
RemoteSectionView.swift (embedded in HomeView, not a tab)
┌─────────────────────────────────────────┐
│ "Remote" header + add button            │──→ inline; opens AddS3ProviderView sheet
│ ┌─────────────────────────────────────┐ │
│ │ RemoteSourceRow (label + s3:// path) │ │──→ tap → RemoteBrowserView.swift
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
│ "More" toolbar menu:                     │
│   frequency, last synced, sync now,      │──→ ProviderStore.updateSyncFrequency /
│   sync queue, delete                     │     SyncEngine.sync(providerRecord:) /
│                                          │     SettingsViewModel.delete(_:)
└─────────────────────────────────────────┘
```
