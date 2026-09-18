# Backup & Restore

`LibrarySnapshot` (Codable) + `BackupService`, which builds one from the DB
(`Sources/DB`), encodes it as JSON, and applies it back. No credentials or
synced track/library rows travel in it — those are Keychain-only or rebuilt
by `Sources/Library/Sync.swift`. What *does* travel is whatever a resync
can't rebuild: speaker bio/photo edits (`ArtistEntry`, keyed by name),
episode edits (`EpisodeEntry`), and transcripts with their corrections
(`TranscriptEntry`) — machine-made, but costing an hour of battery or real
money to make again, and the corrections are hand-typed.

Snapshot decoding is hand-written on purpose: a synthesized `init(from:)`
ignores a property's default and demands the key, so every field added after
v1 would make older archives undecodable rather than partially restorable.

What actually ships is a zip (`BackupService.archive`/`unarchive`, via the
hand-rolled `ZipArchive` — store-only, no compression): `snapshot.json` at
the root plus any referenced speaker photos under `photos/`, so a photo
edit survives a reinstall/new-device restore the same as a bio edit does.

`AutoBackup` keeps those copies current on its own — foreground-only like
`SyncScheduler`, one archive built per run and shipped to every destination
that's switched on, only when something changed and at most every 15 minutes.
`markChanged()` is called from `.libraryDidChange` plus the transcript paths
that don't post it. Two destinations, each its own switch:

- **iCloud Drive** (`CloudDrive`) — the one with nothing to set up, so it's the
  default offer, and the one that outlives deleting the app. Archives only,
  never the live SQLite file: iCloud syncs file-at-a-time and knows nothing
  about WAL sidecars. One file per calendar month
  (`Documents/202609-byopo.zip`, see `BackupArchiveName`), rewritten every run
  until the month turns over: a single overwritten file kept no history, so a
  mistake noticed a week later had already been backed up over, while a zip per
  run turns a document-scope-public folder (`NSUbiquitousContainers`) the
  listener opens in Files into a pile to tidy up. The name is the sort order —
  zero-padded month first — so "newest archive" is `max()` over the names, with
  no dates to parse. A fresh install finds it as an undownloaded placeholder
  (listed under a hidden `.<name>.icloud`), so the read asks iCloud for it and
  waits. The old single file is still read when it's all that's there.
  `CloudDriveStatus` splits "unavailable" into the four causes that need four
  different things said (`notEntitled` / `driveOff` / `notReady` / `ready`),
  checking the build's entitlement *before* `ubiquityIdentityToken` — that
  token needs the iCloud entitlement itself, so in a free-team build it reads
  nil and is indistinguishable from a signed-out account.
- **The S3 bucket** — switched on when a connection is added (an explicit "off"
  is respected), toggled from the connection's own row in `RemoteSectionView`.

Two manual front ends, same archive format, in `Sources/Screens/Settings`:
- Export/Import: `.fileExporter`/`.fileImporter` — user picks the `.zip` file.
- Backup/Restore: `S3Provider.uploadBackup`/`downloadBackup` — derived key in
  the active S3 provider's bucket, no picker:
  `bring-your-own-podcasts/<YYYYMM>-byopo.zip`. Restore lists that folder and
  takes the newest month (a device back from a reinstall hasn't written this
  month's yet), then falls back to the keys older builds wrote.

## Coming Back After a Reinstall

`FirstRunRestore` runs on launch, once, and only onto a library with nothing in
it: it pulls the newest iCloud archive back and applies it without asking —
on a first launch nobody has the context to answer "restore from backup?", and
getting the data back is the point of having taken it. A container that isn't
ready yet isn't a failure; the flag stays unset and it tries again next launch.

The catch is ordering: a reinstall restores before a single episode has synced,
so everything keyed to a file — playlist track order, hand edits, transcripts —
has nothing to attach to yet. `PendingRestore` keeps the archive and re-applies
it (`BackupApplyScope.needsSyncedTracks`) after every `SyncEngine.sync`, until
`awaitingSync` reaches zero. That scope deliberately leaves sources, playlists
and speakers alone, so a playlist deleted since the restore stays deleted.

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
