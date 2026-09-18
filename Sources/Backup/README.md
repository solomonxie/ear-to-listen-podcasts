# Backup & Restore

Three tiers, each answering a failure the others don't.

| Tier | Answers | Survives deleting the app | Cadence | Retention |
|---|---|---|---|---|
| **1. This phone** — `LocalBackups`, `ChangeLog` | the data is still here and now **wrong**: a bad import, the wrong archive restored, an edit nobody meant | No | on app-background, max daily; plus before any large operation; log on every write | 7 days, by age |
| **2. iCloud Drive** — `CloudDrive` | phone lost or app reinstalled; also "let me see the file myself" | Yes | daily, only if changed | latest 10, older pruned |
| **3. The S3 bucket** — `S3Provider` | everything else, plus "what did this look like in March" | Yes | daily, only if changed | never deleted |

Tier 1 not surviving deletion isn't a weakness, it's a different job: it's the
only copy that's instant, offline and there the moment it's wanted. Most real
loss isn't a lost phone — it's an operation that did exactly what it was asked
to, on data nobody meant. So it is never offered as a *destination*: it shares
the app's sandbox, and deleting the app takes it and the library together.

## What travels

`LibrarySnapshot` (Codable) + `BackupService`, which builds one from the DB
(`Sources/DB`), encodes it as JSON, and applies it back. No credentials or
synced track/library rows travel — those are Keychain-only or rebuilt by
`Sources/Library/Sync.swift`, and Settings says so ("keys never leave this
device, including in backups"). What *does* travel is whatever a resync can't
rebuild: speaker bio/photo edits (`ArtistEntry`, keyed by name), episode edits
(`EpisodeEntry`), and transcripts with their corrections (`TranscriptEntry`) —
machine-made, but costing an hour of battery or real money to make again, and
the corrections are hand-typed.

Snapshot decoding is hand-written on purpose: a synthesized `init(from:)`
ignores a property's default and demands the key, so every field added after
v1 would make older archives undecodable rather than partially restorable.

What ships is a zip (`BackupService.archive`/`unarchive`, via the hand-rolled
`ZipArchive` — store-only, no compression), the same bytes to every tier:

```
20260918-ear-to-listen.zip
├── snapshot.json        version, user-authored data, connection list (no secrets)
├── photos/<file>.jpg    speaker photos referenced by snapshot.json
├── artwork/<file>.jpg   episode artwork
└── change-log/<day>.jsonl   what was written, and when — carried, never replayed
```

## Tier 1: the copies that stay here

`LocalBackups` runs on app-background, at most once a day, and only if the
change log moved. Copying megabytes per keystroke to guard against a
once-a-year event is the wrong trade, and the log covers what falls between.
It keeps three different things:

- **Database copies** (`<appSupport>/snapshots/20260918-ear-to-listen.sqlite`) — the
  file itself, not a zip, so putting one back is a swap, and it's the only copy
  that survives a schema problem no row-level undo can fix. The WAL is
  checkpointed first (`DatabaseManager.checkpoint()`) or the copy is missing
  the newest writes.
- **The change log** (`ChangeLog`, `<appSupport>/change-log/<day>.jsonl`) — one
  line per row written, old value beside new, appended and never rewritten.
  Only the tables a backup carries are logged; synced rows are left out, since
  a library re-scan would bury the handful of lines anyone would want to read.
  It also supplies the high-water mark every other tier's schedule gate reads.
- **Archive zips** in the Documents folder (`UIFileSharingEnabled`), so one can
  be dragged out to anywhere.

A large operation — an import, a restore, accepting a whole album's AI
suggestions — writes an extra zip under a name of its own first
(`ear-to-listen-before-import-20260918-140233.zip`), so the day's rolling copy can't
overwrite it and it's obvious at a glance what it precedes. This is the copy
that actually gets used: a bad import lands minutes after the day's backup
caught the good state, or hours after, having caught nothing.

Pruned by age, not by count: once an operation can add files, a count silently
decides how many imports it takes to lose yesterday. "Anything from the last
week" is a promise that stays true. Tier 2 inverts it — there the listener pays
for the storage, and a count is what bounds the bill. Tier 3 deletes nothing:
write-only credentials are the common case and the right default anyway, since
a bucket that can't delete can't be wiped by a bug in this app.

## Off-device: one gate, two destinations

`AutoBackup` is foreground-only (no background-refresh entitlement), builds one
archive per run and ships it to every destination switched on. A destination is
due once a day, and only if `ChangeLog.mark` moved since the copy it already
holds. The mark is written down **only after a successful upload** — record it
before, and a failed upload is remembered as done, so the next day's gate sees
nothing new and skips, indefinitely.

- **iCloud Drive** (`CloudDrive`) — nothing to set up, so it's the default
  offer, and it outlives deleting the app. Archives only, never the live SQLite
  file: iCloud syncs file-at-a-time and knows nothing about WAL sidecars. One
  file per day, latest 10 kept (`BackupArchiveName`); the name is the sort
  order — zero-padded date first — so "newest archive" is `max()` over the
  names, with no dates to parse. Monthly names from earlier builds still sort
  and still restore, ranking as the first of their month. A fresh install finds
  the newest as an undownloaded placeholder (a hidden `.<name>.icloud`), so the
  read asks iCloud for it and waits. `CloudDriveStatus` splits "unavailable"
  into the four causes that need four different things said (`notEntitled` /
  `driveOff` / `notReady` / `ready`), checking the build's entitlement *before*
  `ubiquityIdentityToken` — that token needs the iCloud entitlement itself, so
  in a free-team build it reads nil and is indistinguishable from a signed-out
  account.
- **The S3 bucket** — switched on when a connection is added (an explicit "off"
  is respected), toggled from the connection's own row in `RemoteSectionView`.
  Key: `ear-to-listen-podcasts/20260918-ear-to-listen.zip`. Restore lists that folder
  and takes the newest date (a device back from a reinstall hasn't written
  today's yet), then falls back to the keys older builds wrote.

Manual front ends, same archive format, in `Sources/Screens/Settings`:
Export/Import via `.fileExporter`/`.fileImporter`, and Backup/Restore via
`S3Provider.uploadBackup`/`downloadBackup` (derived key, no picker).

## Restore builds a new library

`DatasetRestore` fills a **new, empty, migrated database** from the archive and
only then puts it in place — nothing of the live library is touched until that
has all worked. The swap goes through the connection the app already holds
(`DatabaseManager.replaceContents(with:)`), so nothing is left reading a
database nobody writes to any more. The library it replaced is kept as a file
for a week, and Settings offers one button to put it back.

The dangerous direction is a bad local state overwriting a good copy somewhere
else, not the other way round — which is why the tiers lean as they do: tier 1
makes undoing possible without touching a remote copy, tier 3 can't delete, and
a restore never merges into what's there.

Everything in the new library is waiting on a sync, since it holds what the
archive held and no episode files. That's the same shape as a reinstall, and
`PendingRestore` handles both.

## Coming Back After a Reinstall

`FirstRunRestore` runs on launch, once, and only onto a library with nothing in
it: it pulls the newest iCloud archive back and applies it without asking — on
a first launch nobody has the context to answer "restore from backup?", and
getting the data back is the point of having taken it. It's the one restore
that doesn't build a dataset of its own: there's nothing to overwrite and
nothing to undo. A container that isn't ready yet isn't a failure; the flag
stays unset and it tries again next launch.

The catch is ordering: a reinstall restores before a single episode has synced,
so everything keyed to a file — playlist track order, hand edits, transcripts —
has nothing to attach to yet. `PendingRestore` keeps the archive and re-applies
it (`BackupApplyScope.needsSyncedTracks`) after every `SyncEngine.sync`, until
`awaitingSync` reaches zero. That scope deliberately leaves sources, playlists
and speakers alone, so a playlist deleted since the restore stays deleted.

## Restore Workflow

```
DatasetRestore.swift:restore(_:)
        │ tier-1 copies first: the zip for anywhere, the .sqlite for here
        ▼
   DatabaseManager.makeDataset(at:)  — empty, migrated, nothing live touched
        ▼
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
        ▼
   DatabaseManager.replaceContents(with:) — the swap, through the live connection
```
