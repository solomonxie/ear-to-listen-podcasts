# Backup & Restore

`LibrarySnapshot` (Codable) + `BackupService`, which builds one from the DB
(`Sources/DB`), encodes it as JSON, and applies it back. No credentials or
synced track/library rows travel in it — those are Keychain-only or rebuilt
by `Sources/Library/Sync.swift`. Speaker bio/photo edits are the one bit of
library data that *does* travel (`ArtistEntry`, keyed by name), since those
are manual edits sync can't rebuild on its own.

What actually ships is a zip (`BackupService.archive`/`unarchive`, via the
hand-rolled `ZipArchive` — store-only, no compression): `snapshot.json` at
the root plus any referenced speaker photos under `photos/`, so a photo
edit survives a reinstall/new-device restore the same as a bio edit does.

Two front ends, one archive format, wired in `Sources/Screens/Settings`:
- Export/Import: `.fileExporter`/`.fileImporter` — user picks the `.zip` file.
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
        ▼
   for each artist entry (matched by name, not the old device's id)
        └─ LibraryStore.swift:upsertArtist(name:) then updateArtist/updateArtistPhoto
           — pre-seeds the row if this speaker hasn't synced here yet; a later sync's
           own upsertArtist(name:) finds and reuses it rather than creating a duplicate
```
