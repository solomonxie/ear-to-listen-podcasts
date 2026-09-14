# Remote Section

Embedded in the single-page root (`HomeView`), not a standalone tab. Backed by
the real `ProviderStore`/`SyncEngine` — `RemoteSectionView` lists actual S3
`ProviderRecord`s (shared `SettingsViewModel` with the Settings section) and a
"Continue Listening" shelf from `TrackStore.recentlyPlayed()`. Tapping a
connection goes straight into `RemoteBrowserView` (no separate detail
screen) — its root level (no folder) also carries the connection's sync
controls, synced-episode list, and storage stats. It recursively browses the
real provider one directory level at a time (`CloudProvider.listDirectory`),
with a "Sync Folder" action that enqueues that level's files into the sync
queue.

Multiple connections can point at the same bucket with different key
prefixes — each row shows a small gray `s3://bucket/prefix` subtitle so
they're told apart (`ProviderManager.s3DisplayPath`).

## Sync queue

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

The queue is global across every source, not per-bucket, so it isn't reached
from inside `RemoteBrowserView`: `RemoteSectionView` shows a one-line status
("Sync queue: N pending · concurrency") below the connections list, tapping
into `SyncQueueView` for the full list, pause/resume, speed, and clear
controls (all on the "Queue (N)" row itself, not a separate on/off toggle).

## Screen Composition

```
RemoteSectionView.swift (embedded in HomeView, not a tab)
┌─────────────────────────────────────────┐
│ "Continue Listening" shelf              │──→ TrackStore.recentlyPlayed() → RealPlayerView
│ "Remote" header + add button            │──→ inline; opens AddS3ProviderView sheet
│ ┌─────────────────────────────────────┐ │
│ │ RemoteSourceRow (label + s3:// path) │ │──→ tap → RemoteBrowserView.swift
│ │   long-press → Delete                │ │──→ SettingsViewModel.delete(_:)
│ └─────────────────────────────────────┘ │
│ "Sync queue: N pending · …" (text)      │──→ tap → SyncQueueView.swift
└─────────────────────────────────────────┘
        │
        ▼
RemoteBrowserView.swift (pushes itself per subfolder)
┌─────────────────────────────────────────┐
│ Subfolders + files at this level         │──→ CloudProvider.listDirectory(atFolder:)
│ Root only: one-line stats footer         │──→ TrackStore.stats(forProvider:)
│ "More" toolbar menu:                     │
│   sync this folder, frequency,           │──→ SyncQueueManager.enqueueFolder /
│   last synced, sync now, delete (root)   │     ProviderStore.updateSyncFrequency /
│                                          │     SyncEngine.sync(providerRecord:)
└─────────────────────────────────────────┘
```
