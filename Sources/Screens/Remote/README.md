# Remote Section

Embedded in the single-page root (`HomeView`), not a standalone tab. Backed by
the real `ProviderStore`/`SyncEngine` — `RemoteSectionView` lists actual S3
`ProviderRecord`s (shared `SettingsViewModel` with the Settings section),
`RemoteSourceDetailView` exposes sync frequency, manual sync, and storage
stats from local metadata.

`RemoteBrowserView` (folder browsing) is still a static mock tree
(`MockData.remoteTree`) — real recursive browsing is backlog.

## Structure

```
Sources/Screens/Remote/
├── RemoteSectionView.swift       lists ProviderRecords (S3 + local), embedded in HomeView
├── RemoteSourceDetailView.swift  sync frequency, manual "Sync Now", storage stats
└── RemoteBrowserView.swift       folder browser — still backed by MockData.remoteTree
```
