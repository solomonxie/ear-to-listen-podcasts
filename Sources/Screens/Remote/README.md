# Remote Section

Embedded in the single-page root (`HomeView`), not a standalone tab. Backed by
the real `ProviderStore`/`SyncEngine` — `RemoteSectionView` lists actual S3
`ProviderRecord`s (shared `SettingsViewModel` with the Settings section),
`RemoteSourceDetailView` exposes sync frequency, manual sync, and storage
stats from local metadata.

`RemoteBrowserView` (folder browsing) is still a static mock tree
(`MockData.remoteTree`) — real recursive browsing is backlog.

## Screen Composition

```
RemoteSectionView.swift (embedded in HomeView, not a tab)
┌─────────────────────────────────────────┐
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
│ "Browse Files" row                      │──→ tap → RemoteBrowserView.swift (folder tree)
│ Sync section: frequency picker,         │──→ ProviderStore.updateSyncFrequency /
│   last synced, "Sync Now"               │     SyncEngine.sync(providerRecord:)
│ Storage section: episode count, size,   │──→ TrackStore.stats(forProvider:)
│   missing-since-last-sync count         │
└─────────────────────────────────────────┘
```

`RemoteBrowserView`'s folder tree still reads `MockData.remoteTree` — real
recursive browsing of the provider is backlog.
