# Remote Section

Embedded in the single-page root (`HomeView`), not a standalone tab. Backed by
the real `ProviderStore`/`SyncEngine` — `RemoteSectionView` lists actual S3
`ProviderRecord`s (shared `SettingsViewModel` with the Settings section) and a
"Continue Listening" shelf from `TrackStore.recentlyPlayed()`.
`RemoteSourceDetailView` exposes sync frequency, manual sync, and storage
stats from local metadata. `RemoteBrowserView` recursively browses the real
provider one directory level at a time (`CloudProvider.listDirectory`), with a
"Sync Folder" action that enqueues that level's files into the sync queue.

## Sync queue

Per-file jobs (`SyncJob`, in `syncJobs`) persist across launches. `SyncQueueManager`
drains pending jobs with bounded concurrency, calling
`SyncEngine.importFileIfNeeded` per file — the same import path the
whole-bucket `SyncEngine.sync(providerRecord:)` uses. `SyncQueueView` shows the
overall queue and its pause/clear/concurrency controls.

## Screen Composition

```
RemoteSectionView.swift (embedded in HomeView, not a tab)
┌─────────────────────────────────────────┐
│ "Continue Listening" shelf              │──→ TrackStore.recentlyPlayed() → RealPlayerView
│ "Remote" header + add button            │──→ inline; opens AddS3ProviderView sheet
│ ┌─────────────────────────────────────┐ │
│ │ RemoteSourceRow (per S3/local        │ │──→ inline (same file)
│ │   ProviderRecord)                    │ │
│ └─────────────────────────────────────┘ │──→ tap → RemoteSourceDetailView.swift
└─────────────────────────────────────────┘
        │
        ▼
RemoteSourceDetailView.swift
┌─────────────────────────────────────────┐
│ "Browse Files" row                      │──→ tap → RemoteBrowserView.swift (real folders)
│ Sync section: frequency picker,         │──→ ProviderStore.updateSyncFrequency /
│   last synced, "Sync Now"               │     SyncEngine.sync(providerRecord:)
│ Storage section: episode count, size,   │──→ TrackStore.stats(forProvider:)
│   missing-since-last-sync count         │
└─────────────────────────────────────────┘
        │
        ▼
RemoteBrowserView.swift (pushes itself per subfolder)
┌─────────────────────────────────────────┐
│ Subfolders + files at this level        │──→ CloudProvider.listDirectory(atFolder:)
│ "Sync Folder" toolbar button            │──→ SyncQueueManager.enqueueFolder → SyncQueueView
└─────────────────────────────────────────┘
```
