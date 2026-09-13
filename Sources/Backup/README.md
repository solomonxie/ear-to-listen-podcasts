# Backup & Restore

`LibrarySnapshot` (Codable) + `BackupService`, which builds one from the DB
(`Sources/DB`), encodes/decodes it as JSON, and applies it back. No
credentials or track/library rows travel in it — those are Keychain-only or
rebuilt by `Sources/Library/Sync.swift`.

Two front ends, one snapshot format, wired in `Sources/Screens/Settings`:
- Export/Import: `.fileExporter`/`.fileImporter` — user picks the file.
- Backup/Restore: `S3Provider.uploadBackup`/`downloadBackup` — fixed key in
  the active S3 provider's bucket, no picker.

## Restore Workflow

```
BackupService.swift:apply(_:)
        │ providers/importSources: insert only if id not already present (credential-less)
        ▼
   for each playlist in the snapshot
        │ create if id not already present
        ▼
   for each track ref (providerID + filePath, not the old device's track id)
        ├─ TrackStore.swift:find(providerID:filePath:) hit ──► PlaylistStore.swift:addTrack(_:toPlaylist:at:)
        └─ miss (not synced on this device yet) ──► counted as unmatched, not linked
```
