# 08 Backup (`Sources/Backup`)

Files read in full: `AutoBackup.swift`, `BackupArchiveName.swift`, `BackupService.swift`, `ChangeLog.swift`, `CloudDrive.swift`, `DatasetRestore.swift`, `FirstRunRestore.swift`, `LocalBackups.swift`, `PendingRestore.swift`, `Snapshot.swift`, `ZipArchive.swift`, `README.md`. Also read, to confirm findings: `Providers/CloudBackup.swift`, `DatabaseManager` (`makeDataset`, `checkpoint`, `replaceContents`), `SettingsViewModel` (restore, preview, export, undo, remove-all), `BackupSettingsView`, `ProviderStore.all/active`, `LibraryStore.updateArtist/updateAlbum`, `TrackStore.upsert/sameRecording/relink/point`, `Migrations` v41 and table list, `ImageFileStore`, `SyncQueueManager.reapplyPendingRestore`, `Album`/`Artist`/`Track` models, `Tests/BackupServiceTests.swift`, `Tests/CloudBackupTests.swift`.

Already covered elsewhere and not repeated: the pre-restore/undo `.sqlite` is a raw file copy taken while writes may be in flight (01 #4, which applies to `LocalBackups.copyDatabase` and so to both the daily copy and the restore undo point); `find(filePath:)` full scans called per backup entry (01 #11); `downloadBackup` swallowing every listing/download error (03); `ArtworkSidecar` orphan images and restore re-writing every bundled image (07 #8). The `artwork/../` traversal 07 flagged for this step is confirmed below as #2.

**Secrets: clean.** No keychain item, provider config or AI key reaches the archive or the change log. `ProviderEntry` carries id/type/label/flags only, provider rows come back with `configJSON: ""`, and `ChangeLog` logs sources as `type`/`label` only. Track rows logged by `saveEdit` hold no URLs or tokens.

Summary: the tiers, the empty-archive guard and the staged swap are well thought out, and `replaceContents` (SQLite backup API through the live connection) is a real atomic swap. The weak half is *merge*. `apply` overwrites rather than fills in, is not one transaction, and `PendingRestore` re-runs it after every sync for up to 30 days. So a restore keeps reverting what the listener does afterwards. The archive also misses whole tables of hand edits (albums, most speaker fields), the zip reader trusts entry names, and the daily copy written right after a reinstall restore overwrites the one it came from. Most restore work runs on the main actor and holds several full copies of the archive in memory. **P0 1 · P1 5 · P2 9 · P3 12**

## P0

**1. A merge restore keeps overwriting the listener's later edits after every sync, for up to 30 days.**
`BackupService.swift:234-288`; `PendingRestore.swift:32-43`; `DatasetRestore.swift:60`, `:67`; `SyncQueueManager.swift:244-247`
- The doc on `apply` (`:228`) and the README say it "never overwrites what's already there". The episode loop does: for every matched episode it sets `title`, `notes`, `artworkFileName`, `year`, `artistID`/`albumID` and `metadataEditedAt` from the archive (`:273-282`). A nil `notes` or `editedAt` in the archive *clears* the local value. `setTerms` replaces the term list. Transcripts merge the archive's machine text over any unedited span (`TranscriptStore.merging`), and `engine` is overwritten.
- `scope: .needsSyncedTracks` only skips providers, import sources, speakers and new playlists. The episode, bookmark, favourite, `listenedAt`, `neglectedAt` and transcript passes run in full on every re-apply.
- `DatasetRestore` keeps the archive in `PendingRestore` while `awaitingSync > 0`. In the merge path that stays above zero for any episode whose bucket is still connected but whose file was since deleted or renamed, or any playlist ref to one. Those never match, so the archive is re-applied after every sync drain until the 30-day expiry.
- Scenario: the listener restores a week-old archive onto a living library. One episode in it was since deleted from the bucket. Next day they rename an episode, unfavourite another, delete a bookmark and mark one unplayed. The next scheduled sync puts back the old title, the favourite, the bookmark and the `listenedAt`. With `metadataEditedAt` reset to nil where the archive had none, the following tag pass can then re-derive over hand edits. Undo only goes back to before the restore, so it loses everything since.
- Fix: make apply fill-only. Write a field only when the local one is nil, or when `entry.editedAt > track.metadataEditedAt`; never clear. Apply favourite, listened, neglected, bookmarks and terms only when the episode is first linked. For the re-apply, process only entries that matched nothing on earlier passes: keep the set of applied `(providerID, filePath)` keys beside `pending-restore.zip`, and stop counting entries whose provider is connected and has completed a full listing without the file.

## P1

**2. `unarchive` writes zip entry names straight to disk. A crafted archive can overwrite any file in the sandbox.** (Flagged by 07.)
`BackupService.swift:219-223`; `ImageFileStore.swift:24-27`; `SettingsViewModel.swift:334-344`
- `fileName` is everything after `artwork/` or `photos/`, so `artwork/../ear-to-listen.sqlite` or `photos/../../Preferences/<bundle>.plist` resolves outside the image folder. The write is not atomic, and failures are swallowed.
- The images are also written *before* `decode` checks the version (`:225`) and before `DatasetRestore` refuses an empty archive (`DatasetRestore.swift:47-50`). A refused archive still drops its files.
- Scenario: someone shares "my backup" and the listener picks it in Import Library Data. The preview reads `snapshot.json` and looks normal. Restore replaces the live database file underneath GRDB, or plants a preferences plist.
- Fix: accept only a single path component (`!name.isEmpty`, no `/`, no `..`, matching the generated-name pattern). Check `url.standardizedFileURL` stays under `store.directory`. Decode and validate the snapshot first, then write images to a staging folder and move them in after `apply` succeeds.

**3. Restore has no rollback. A failure part-way leaves the live library half-merged, and the undo button is not offered.**
`DatasetRestore.swift:54-64`; `BackupService.swift:234-338`; `FirstRunRestore.swift:51-64`
- `apply` runs every store call in its own `dbQueue.write`. A throw on entry 3,000 (disk full, or a unique-index clash in `upsertArtist`/`upsertAlbum`, see 01) leaves 2,999 merged.
- `previousKey` is only set after `apply` returns (`:61-64`), so on a throw the pre-restore `.sqlite` is on disk but `replacedLibraryAt` is nil and Settings shows no undo.
- The safety copies are optional: `try? live.currentArchive()` and a nil `copyDatabase` both let the restore go ahead with no undo point. `backUpBeforeDeletion` treats a failed local copy as fatal, and a restore should too.
- `FirstRunRestore` applies straight into the live DB with `try?`. A throw after the provider placeholders were inserted leaves `didRestoreKey` unset, but `shouldRun` now sees `providers > 0` and never retries. The partial restore is permanent and nobody is told.
- Fix: refuse to restore when either safety copy fails. Merge into a staged copy of the live DB (`dbQueue.backup(to:)` into a staging file, apply there, then `replaceContents`), which also gives the merge path the same atomicity as `swapIn`. Or wrap `apply` in one `dbQueue.write` by giving the stores `Database`-level variants. Record `previousKey` before applying.

**4. Albums and most speaker edits are not in the archive at all, and album edits don't trigger a backup.**
`BackupService.swift:79-87`; `Snapshot.swift:56-63`, `:194-201`; `LibraryStore.swift:157-171`; `AlbumDetailView.swift:428-429`
- `LibrarySnapshot` has no album entry. Album `notes`, `profile`, `artworkFileName`, `year`, `language` and `neglectedAt` never travel. `updateAlbum` and `updateAlbumLanguage` don't call `ChangeLog.record`, so an album edit doesn't move the mark and schedules no backup.
- `ArtistEntry` carries `bio`, `language` and `photoFileName` only. `knownFor`, `background`, `link`, `profile` and `neglectedAt` are dropped. A speaker whose only edit is an AI-written profile is filtered out entirely (`:82`).
- Episode `listenLater` and `language` are also missing, though `listenLater` changes are logged and do trigger backups.
- Scenario: the listener writes album profiles and speaker pages for a month, then reinstalls. Every one is gone. The "before album-profile" copy `AlbumDetailView` writes before an AI pass can't undo that pass, because it doesn't contain album fields.
- Fix: add an `AlbumEntry` (keyed by speaker name + album name, artwork under `artwork/`) and the missing artist and episode fields, bump `currentVersion`, and log album writes in `LibraryStore`.

**5. Restoring onto a library with no episodes swaps the whole database. Connected sources, AI keys and query history are wiped.**
`DatasetRestore.swift:60`, `:72-90`
- `hasALibrary` only counts tracks and playlists. With neither, `swapIn` replaces every table with a fresh DB filled from the archive. That covers `providers`, `aiKeys`, `aiQueries`, `fixHistory`, `syncJobs`, `terms` and every table the snapshot doesn't carry.
- Scenario: on a new phone the listener connects their bucket (a new provider id), adds an AI key, then imports an archive from Files before the first sync has listed anything. After the restore the new connection is gone (or replaced by the archive's inactive, credential-less row) and the AI key row has vanished, leaving its keychain secret orphaned. Nothing in the result message says so.
- Fix: count providers (`ProviderStore.all()`) and AI keys in `hasALibrary`, or carry the live rows the archive doesn't hold into the staged DB before the swap (providers not in the archive, `aiKeys`, `aiQueries`, `fixHistory`).

**6. The backup written right after a reinstall restore overwrites the archive it was restored from, dropping its change log. With an older app it overwrites a newer archive.**
`AutoBackup.swift:47-52`, `:84-87`; `FirstRunRestore.swift:36-38`; `CloudDrive.swift:65-73`; `BackupService.swift:211-213`, `:449-459`
- `enableCloudDriveAfterRestore` flips `isCloudDriveEnabled`, whose `didSet` calls `backUp(toCloudDrive: true)` with no due check. It writes `BackupArchiveName.current()`, which is today's name.
- When the archive restored is today's (the common case after a same-day reinstall), the rebuilt copy replaces it. `unarchive` leaves the `change-log/` entries behind, so the new copy carries only the handful of lines the restore itself logged. The design promise that "every archive carries the history from day one" ends with that file, and the older dailies that still have it are pruned after ten more change-days.
- Every episode in the rebuilt copy is parked under `lost/…` (fresh install, so `knownProviderIDs` is empty), which feeds #13.
- `holdsData` returns false both for "empty" and for "can't decode" (`unsupportedVersion`). An older build on a second device or a downgraded TestFlight skips today's newer-version archive, silently restores an older one, then overwrites the newer one under today's name.
- Fix: don't back up after a restore until the first sync has re-linked the episodes, or until the next due run. Never overwrite an existing same-name archive that holds data from another install or a newer `version`; write under a fresh name in that case. Restore the `change-log/` files into `ChangeLog.directory` (under a per-install prefix). Make `holdsData` distinguish "newer version" and stop the first-run restore with a visible message instead of falling back.

## P2

**7. Archive names use `Calendar.current`. Non-Gregorian calendars break sorting, and iCloud prune then deletes the file it just wrote.**
`BackupArchiveName.swift:48-77`; `CloudDrive.swift:78-89`; `ChangeLog.swift:78-81`
- `dateComponents([.year])` returns the era year in the Japanese calendar (`0008` for 2026) and 2569 in the Buddhist one. Names are compared as text.
- Scenario: a listener with ten Gregorian-named dailies in iCloud switches the region calendar to Japanese. Each new `00081016-daily-…` ranks oldest, so `prune` deletes it straight after the write while `lastCloudDriveBackupAt` reports success. Backups have silently stopped. A Buddhist-calendar device's names outrank every Gregorian copy for ever, so a restore picks them over newer ones.
- Local-time names also misorder across time-zone travel. Flying east to west can make the next day's run reuse yesterday's name.
- Fix: format with `Calendar(identifier: .gregorian)` and a fixed `TimeZone` (UTC, or keep local but always Gregorian). Do the same for `ChangeLog.fileName`.

**8. Whole-library snapshot, zip and merge run on the main actor.**
`SettingsViewModel.swift:240`, `:313`, `:338`, `:351`; `AutoBackup.swift:157-165`; `AlbumDetailView.swift:428`; `SpeakerDetailView.swift:303`; `AlbumAnalysisView.swift:160`
- `AutoBackup.buildArchive` says it is "seconds of work on a big library, so never on the main thread" and detaches. Every other caller doesn't. Import runs `unarchive`, `currentArchive`, `copyDatabase` and the per-episode `apply` (~8 transactions per episode, plus 01 #11) synchronously on main. Export, preview (full file read plus `[UInt8]` copy), undo, Remove All Data's snapshot and archive, and the three "before" copies taken before AI passes all do the same.
- Scenario: restoring a 5k-episode archive freezes the UI long enough for the watchdog. Tapping "Generate profile" on an album stalls for seconds before the request even starts.
- Fix: run these in `Task.detached` (as `buildArchive` and `reapplyPendingRestore` do) and publish the result back. Show progress for restore.

**9. Building or reading an archive holds three to four full copies in memory. PLAUSIBLE that it jetsams a large library in the background.**
`BackupService.swift:58-209`, `:168`; `ZipArchive.swift:13-72`, `:76-91`; `AutoBackup.swift:131-139`
- Build: every transcript's segments as structs, then pretty-printed, key-sorted JSON (`.prettyPrinted` roughly doubles segment JSON), then every image and log file as `Data`, then `ZipArchive.write` appends all of it into one more `Data`. Read: `[UInt8](data)` copies the archive, then each entry is copied again into its own `Data`.
- Scenario: 2,000 transcribed hour-long episodes is a few hundred MB of JSON, so peak use is around 1 GB. `backUpOnLeaving` builds this in the background, where the memory limit is lower, and the run is killed every time. The mark is never written, so it retries on every leave.
- Fix: stream the zip to a temp file with `FileHandle` (store-only makes this easy), encode compact JSON, and upload or copy from the file. Read with `Data(contentsOf:options: .alwaysMapped)` and slice without the `[UInt8]` copy.

**10. `transcripts(of:)` does two queries per transcript, and a failed read silently drops that transcript from the backup.**
`BackupService.swift:144-148`
- The rest of `makeSnapshot` was rewritten to "one query per table, then matched in memory" (`:92-93`). Transcripts still call `find(trackID:)` and `edits(trackID:)` per record, which breaks the repo's per-item I/O rule. `try? … ?? []` turns a read error into "no transcript", and the archive ships without it.
- Fix: fetch all segments and all edits in one query each, group by `trackID`, and let errors throw.

**11. The once-a-day gate ships the day's *first* state. The rest of the day's work isn't off the phone until tomorrow.**
`AutoBackup.swift:206-214`; `LocalBackups.swift:43-49`; `BackupArchiveName.swift:14-16`
- `isDue` is false once `lastAt` is today, so the first edit of the day ships 60 s later and nothing after it does. `BackupArchiveName` says the daily file is "rewritten by every run that day", which never happens. The tier-1 copy uses the same gate, so the README's claim that the gap is covered by tier 1 holds only for the change log, which is on the same phone.
- Scenario: one note at 08:00 ships at 08:01. Hours of transcript corrections follow, and the phone is lost at 20:00. iCloud and the bucket have the 08:01 state.
- Fix: gate on a minimum interval (for example one hour) rather than calendar day, and keep rewriting today's name.

**12. A bucket switch that stays on with no bucket, or a destination that keeps failing, rebuilds the whole archive after every edit burst and every app leave.**
`AutoBackup.swift:195-204`, `:241-270`
- Removing the bucket doesn't clear `isEnabled`. `noActiveRemoteProvider` and `CloudDriveError` leave the mark and `lastAt` unset, so the destination stays due, and `backUp` builds the full archive (#9) before finding out.
- Fix: check `remoteProviderForAppData() != nil` and `CloudDrive.status().isReady` before building, and back off after a failure (for example, retry at most hourly).

**13. Restoring an episode that was already orphaned prefixes its path a second time, so reconnecting its bucket never re-links it by path.**
`BackupService.swift:258-261`, `:355-367`; `ProviderStore.swift:33-45`; `TrackStore.swift:96-103`
- An orphaned row travels as `providerID "lost"`, `filePath "p1/ep.mp3"`. `knownProviderIDs` comes from `ProviderStore.all()`, which excludes the `lost` row, so `apply` fabricates `lost` / `lost/p1/ep.mp3`. `relink` looks for `lost` / `p1/ep.mp3`, so only the ETag+size fallback can find it. Providers whose ETag is not stable, or missing (multipart S3), get a duplicate episode. The archive written right after a reinstall restore (#6) has every episode in this state.
- `testAnOrphanedEpisodeSurvivesBeingBackedUpAndRestoredElsewhere` checks `isLost` but not the path.
- Fix: when `entry.providerID == OrphanedEpisodes.providerID`, fabricate with `entry.filePath` unchanged.

**14. Undo restore is one tap with no confirmation, discards everything since the restore, and puts back a DB that is not migrated.**
`DatasetRestore.swift:94-103`; `BackupSettingsView.swift:133-141`
- The button stays for up to seven days. Undo replaces the whole live DB, which loses every sync, play position, edit and transcript made since. A stray tap is unrecoverable except through the "before-undo" copy, which nothing in the UI offers. The doc's "undoing an undo is also possible" has no button, because `previousKey` is removed.
- PLAUSIBLE: if an app update with a new migration landed between restore and undo, `replaceContents` copies an older-schema DB into the live connection. GRDB already ran migrations at launch, so queries against new columns throw until the next relaunch.
- Fix: confirm with what will be lost ("changes since <date>"). Run `Migrations.migrator().migrate(restored)` before `replaceContents`. Point `previousKey` at the before-undo copy.

**15. PLAUSIBLE: iCloud files are written and deleted without file coordination, and two devices share one name per day.**
`CloudDrive.swift:69-89`, `:118-126`
- Files in a ubiquity container should be written through `NSFileCoordinator`. A plain `.atomic` write and `removeItem` race the iCloud daemon's upload and can produce conflict versions. Two devices on one Apple ID both write `YYYYMMDD-daily-…`, so the last writer wins, and a lightly used iPad's dailies push the phone's out of the ten kept.
- Fix: coordinate writes and deletes. Add a short install or device tag to daily names, prune per device, and let restore prefer the most complete archive (`contentsSummary` counts) among the newest ones.

## P3

- `ZipArchive.read` never checks CRC and stops quietly at a truncated entry. Because `snapshot.json` is first, a half-downloaded or truncated file restores "successfully" with no images. Verify CRC and the end-of-central-directory entry count, and fail if they don't match. `ZipArchive.swift:76-91`
- `ZipArchive.write` traps on `UInt16(central.count)` past 65,535 entries (one per episode with art, plus one per change-log day) and on `UInt32` past 4 GiB. Throw instead, or dedupe artwork entries by file name. `ZipArchive.swift:29-31`, `:65-66`
- `unarchive` swallows image write failures and `archive` silently skips unreadable images, so a restore can report success with missing pictures. Count and report them. `BackupService.swift:191`, `:198`, `:222`
- `LocalBackups.save` records the mark and `lastAt` even when the zip write or DB copy failed, so the day counts as done. That's the exact mistake `AutoBackup`'s doc warns against. `LocalBackups.swift:51-58`
- `copyDatabase` deletes the existing copy before copying, so a failed copy leaves no copy for the day. Copy to a temp name, then replace. `LocalBackups.swift:80-82`
- `PendingRestore.reapplyAfterSync` swallows unarchive and apply errors and retries on every sync for 30 days. Each pass rewrites every bundled image (`unarchive`). Unpack images once at restore, re-apply from the decoded JSON, and give up after N failures. `PendingRestore.swift:38-42`
- `FirstRunRestore.apply` saves `PendingRestore` even when `awaitingSync == 0`, so one needless full re-apply follows the first sync. `FirstRunRestore.swift:68`
- `ChangeLog.record` does a read-modify-write of the mark from whatever thread writes, and posts one main-queue notification per row. A restore applying thousands of bookmarks floods the main queue and can lose increments. Increment on the `writes` queue and coalesce the post. `ChangeLog.swift:52-54`
- `backUp` silently returns when a run is in flight, so a toggle-on that collides with a scheduled run shows nothing. `AutoBackup.swift:196`, `:217`
- Dead code: `AutoBackup.backUpNow`, `LocalBackups.archives()` and `databaseCopies()` have no callers. `BackupArchiveName.newest(among:)` is test-only. `AutoBackup.swift:141-143`; `LocalBackups.swift:107-113`; `BackupArchiveName.swift:96-98`
- `persist(_:forKey:changedFrom:)` ignores `oldValue`. `AutoBackup.swift:191-193`
- Stale user-facing text: the Backup info row shows `20260918-ear-to-listen.zip` (no `-daily-`) and says restoring "builds a fresh library from the archive", but onto a living library it merges. `BackupSettingsView.swift:61`

## Tests to add

- Re-apply after a sync with an unmatched entry must not revert a rename, unfavourite, deleted bookmark or unplayed mark made after the restore (#1).
- `unarchive` with `artwork/../x` and `photos/` (empty name) entries writes nothing outside the store (#2).
- A throw mid-`apply` leaves the live DB unchanged and the undo offer present (#3).
- Snapshot round-trip of album notes/profile/artwork and speaker `profile`/`knownFor`/`link`/`background` (#4).
- Restore onto a library with a connected provider and an AI key but no tracks keeps both (#5).
- `FirstRunRestore` then the immediate iCloud backup doesn't replace a same-day archive, and keeps the change log (#6).
- `BackupArchiveName` with `Calendar(identifier: .japanese)` and `.buddhist` produces Gregorian stamps (#7).
- Orphaned entry restored onto a fresh DB keeps `filePath == "p1/ep.mp3"`, and re-links when `p1` syncs `ep.mp3` (#13).
- Truncated archive (cut mid-image) is rejected (P3).
