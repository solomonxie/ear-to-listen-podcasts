# 04 Sync (`Library/Sync.swift`, `SyncQueueManager`, `SyncJobStore` usage)

Files read in full: `Library/Sync.swift`, `SyncQueueManager.swift`, `SyncQueuePolicy.swift`, `SyncScheduler.swift`, `SourceRefresh.swift`, `EpisodeUpload.swift`, `ArtworkSidecar.swift`, `LibraryNotifications.swift`, `FileFingerprint.swift`, `DB/SyncJobStore.swift`. Also read the sync-facing parts of `TrackStore` (`registerListed`, `relink`, `markLost`, `refreshCopy`, `applyTags`, `upsert`, `updateTranscriptPaths`), `TrackMerge.foldArrival`, `LocalFilesProvider.listFiles` and every `libraryDidChange` observer.

Summary: the scan/enrich split is sound. One listing, one `byPath` read, one `registerListed` transaction, a `.running` requeue at launch and claim-in-transaction dequeue are all correct. The weak points are the lost state and the queue's failure handling. An empty or short listing marks a whole source lost, and nothing checks it first. Passes for the same provider aren't serialized, so a stale pass marks files lost that a newer pass or an upload just added. Failed jobs never retry, so one offline spell during a first sync leaves the whole tag backlog failed, row by row. **P0 0 · P1 3 · P2 9 · P3 13**

## P1

**1. An empty or short listing marks every episode in the source lost, and nothing checks it first.**
`Sync.swift:135`, `:148`, `:193`; `TrackStore.swift:695-726`; `Providers/Local/LocalFilesProvider.swift:112-117`
- `markLost(keepingPaths: seenPaths)` treats "not in this listing" as "gone". It never checks whether the listing is plausible.
- Ways a listing comes back empty or short without throwing:
  - Local folder: `FileManager.enumerator(at:)` returns nil (the folder was moved, or the security scope wasn't granted), and `listFiles` returns `[]`. The enumerator has no `errorHandler`, so unreadable subtrees vanish silently (03 P3).
  - S3/Azure: a page that fails to parse, or `IsTruncated` with no token, ends the paging loop early (03 P3 "Listing parsers ignore `XMLParser.parse()`'s result"). Sync turns that P3 into the loss below.
- Scenario: a 600-episode local folder is renamed in Files. The next scheduled sync returns `[]`, marks all 600 episodes lost and reports "Nothing new. 600 no longer in the bucket." Flagged then lists 600 "Audio missing" items, and the suggested fix is `.deleteRecord` (`FlaggedFix.swift:51`). Deleting them removes bookmarks, notes, progress and transcripts. Recovery, if the folder comes back, goes through per-file jobs capped at 100 (#4).
- Fix:
  - Make the local provider throw when the enumerator is nil or reports an error, and make the parsers throw on a bad page (03).
  - In `sync`, refuse to mark anything lost when the playable listing is empty but the source has live copies. Hold back when more than about 20% of live copies would go lost in one pass: record it and ask the user ("600 files are gone from X. Mark them missing?").

**2. Passes for the same provider aren't serialized, and `markLost` uses a listing that may be minutes old.**
`SyncQueueManager.swift:120-130`, `:173`, `:219-237`, `:75-83`; `SyncScheduler.swift:47`; `Sync.swift:135-193`; `SyncJobStore.swift:104-116`
- Entry points that run `SyncEngine.sync` with no per-provider guard: Sync Now (two screens), the scheduler, `topUp`, `resumeInterruptedListings` and a listing Retry. `SyncQueueManager` is `@MainActor`, but `sync` suspends on `await`, so calls interleave.
- Between `listFiles` (`:135`) and `markLost` (`:193`), `ArtworkSidecar.adopt` downloads every missing cover one after another, and `YouTubeTranscripts.adopt` downloads transcripts. On a first sync that window lasts minutes.
- Any copy created after the listing was taken is marked lost when `markLost` runs. That includes an upload job finishing in the drain (`EpisodeUpload.send` → `importFileIfNeeded`) and files a newer overlapping pass registered.
- Scenario: the user uploads three episodes from the folder view while the 15-minute scheduled pass is downloading covers. The uploads finish and appear, then the stale pass marks them "Audio missing". On a Manual connection they stay that way until the next Sync Now.
- `startListing` also deletes the other pass's `.running` row (`SyncJobStore.swift:106-108`). When the first pass then calls `finishListing`/`markFailed`, the update finds no row and does nothing, so the queue screen shows one listing while two are running.
- Fix:
  - Keep one in-flight `Task` per providerID in `SyncQueueManager`, and have later callers await it instead of starting another.
  - Make `markLost` skip copies with `addedAt`/`updatedAt` later than the listing's start time. `TrackFile` already has `addedAt`.

**3. Failed jobs never retry, and the drain doesn't check the network. One offline spell fails the whole tag backlog, and each row needs its own Retry.**
`SyncQueueManager.swift:189-214`, `:250-274`; `Sync.swift:367-372`; `SyncJobStore.swift:82-86`, `:135-143`
- The drain never checks `NetworkMonitor`. The only check is in `sync` (`Sync.swift:119`).
- `enrich` offline: S3, Azure and GCS stream URLs are signed locally, so `streamURL` succeeds. Then `asset.load(.commonMetadata)` fails, and the job is marked failed with "couldn't read the file's length".
- `fillTagReads` excludes tracks with a `failed` readTags row (`:85`), so after a failure the next batch is queued and fails too. The loop works through the entire `needsTags` backlog in seconds, and every row ends up failed.
- There is no automatic retry, no backoff and no Retry all. The only way back is a Retry tap per row (`SyncQueueView.swift:32`) or a per-episode `SourceRefresh`. `pruneDone` prunes only `done` rows, so the failed rows stay. `tagsRemaining` keeps counting those tracks.
- The same thing happens when the app is suspended mid-drain. Nothing calls `beginBackgroundTask`, so in-flight `AVURLAsset` loads and uploads fail on resume.
- Scenario: the user adds a 3,000-file bucket and gets on the subway. The scan lands, then all 3,000 tag reads fail within a minute. Back online, every episode is still titled after its filename, with no duration, and there are 3,000 failed rows to retry by hand.
- Fix:
  - Stop claiming jobs while `!NetworkMonitor.shared.isConnected` (except for on-device providers), and resume when the connection comes back.
  - Add `attempts` and `nextAttemptAt` columns. Retry transient failures with exponential backoff (e.g. 1 min, 5 min, 30 min, then failed).
  - Add a Retry all failed action. Wrap the drain in `beginBackgroundTask`, as `AutoBackup` and `TranscriptRunner` already do.

## P2

**4. Changed and returning files go through one queue job each, capped at 100. A bucket that comes back needs one full re-listing per 100 files.**
`Sync.swift:159-179`, `:194`, `:276-284`; `SyncQueueManager.swift:219-237`; `SyncScheduler.swift:45`
- For a known copy that is lost or changed, the job's only effect is `refreshCopy`, a pure DB write (`:276-284`). It still costs:
  - `hasUnfinished` (a read) and `enqueue` (a write transaction) per file inside the listing loop.
  - A claim write, two stage writes, a done write, a `pruneDone` write and a main-actor `providerStore.all()` read per job.
- Past 100 files, `stoppedAtQueueLimit` makes `topUp` re-list the whole bucket for each further batch of 100. That repeats `updateTranscriptPaths`, `ArtworkSidecar.adopt` (#7) and `markLost` each time.
- `lastSyncedAt` isn't written on a stopped pass (`:194`), so the scheduler finds the provider due again and runs another full listing every 60 s alongside `topUp`.
- Scenario: after #1, a 2,000-file bucket comes back. That costs 20+ full listings (S3: 2 pages each) and about 14,000 DB transactions to flip 2,000 `isLost` flags.
- Fix: handle known lost or changed copies in the listing pass with one bulk write, as `registerListed` does for new files. Keep the queue for work that needs the network.

**5. A connection that fails to list is re-listed every 60 s, and each attempt leaves a failed "Listing …" row that is never pruned.**
`SyncScheduler.swift:43-48`; `Sync.swift:120-131`; `SyncJobStore.swift:104-116`, `:135-143`
- `try?` swallows the error, and `lastSyncedAt` isn't updated, so the provider stays due. The next 60-second poll lists it again.
- `startListing` deletes only `.running` listing rows, and `pruneDone` deletes only `done` rows, so each failure adds a permanent failed row.
- Scenario: a revoked key on a 15-minute connection, with the app open for an hour, leaves about 60 failed rows on top of the queue and costs 60 signed requests.
- Fix: store `lastAttemptAt` and a failure count per provider and back off. `startListing` should also replace earlier failed listing rows for that provider. Show the error once, on the connection.

**6. Renames and moves within a bucket can't re-link, because `registerListed` runs before `markLost`.**
`Sync.swift:180-193`; `TrackStore.swift:97-107`, `:123-155`
- `relink` matches by ETag and size only against tracks with `isLost = 1`. The old path is marked lost 12 lines later, in the same pass, so a moved file never matches its episode.
- The moved file becomes a new filename-titled entry, and the old one greys out. The two merge only after a remote tag read (`AVURLAsset`, plus one AI call when tags are incomplete) brings `foldArrival` a fingerprint match.
- If the old track never got a duration, it has no fingerprint, and the duplicate is permanent.
- Scenario: the user sorts 500 S3 files into season folders. That costs 500 remote tag reads (and up to 500 AI calls), and for a while Home shows 500 new episodes next to 500 missing ones.
- Fix: in one transaction, work out which known copies are absent from this listing first. Build a `(hash, size) → trackID` map from them, and re-point arrivals in memory before inserting any new track. Then run `markLost` for the rest.

**7. `ArtworkSidecar.adopt` reads the DB once per copy on every sync, re-downloads images that failed every time, and holds the pass open while it downloads.**
`ArtworkSidecar.swift:112-122`, `:126-137`, `:160-163`; called from `Sync.swift:189`, `:243-245`
- `dbQueue.read { Track.fetchOne }` runs per copy that has a sidecar image, and `Album.fetchOne` per folder. This is the per-item I/O pattern from CLAUDE.md, on every scheduled pass.
- An image that fails to download or decode is fetched again on every pass: `fetch` returns nil, so `artworkFileName` stays nil.
- Downloads run one after another before `markLost`, which widens the window in #2.
- The `onlyPath` call loads every live copy of the provider to adopt for one file.
- Fix: load `(trackID, artworkFileName, metadataEditedAt)` for the provider in one query and filter in memory. Remember failed image paths together with their ETag, and skip them until the ETag changes. Move adoption after `markLost`, or into a queue job.

**8. `SyncQueueManager` does all its DB work synchronously on the main actor, and some of it is whole-library work.**
`SyncQueueManager.swift:99-112`, `:196-208`, `:270-284`
- `refresh()` runs five queries every 400 ms during a drain: `page`, `counts`, `activeProviderIDs`, `needsTagsCount` and `providerStore.all`.
- `nextJob()` runs `dequeueNextPending` and `fillTagReads`, both write transactions. `fillTagReads` has a `NOT IN` subquery over `syncJobs`.
- `process()` runs `providerStore.all()` before each job and a `pruneDone` write after it.
- `numberDuplicateTitles()` runs at the end of every drain that did any work. It loads every track and re-fetches each one it renames, all in one write on the main thread.
- With `DatabaseQueue` (01 #8), each of these also waits behind any background write in progress, such as a whole-bucket `registerListed` or `applyTags`/`foldArrival` (01 #6, #7). The UI freezes for the length of that write.
- Fix: move the store calls to a non-main actor or a detached task and publish the results back. Run `numberDuplicateTitles` detached, as `reapplyPendingRestore` already is. Cache provider records per drain.

**9. `libraryDidChange` fires once per tag read, and four observers don't debounce it.**
Posted per job at `Sync.swift:224`, `:298`, `:310`, `:347`. Observers without a debounce:
- `LibraryNames.swift:21-25`: always alive. Refetches every album and every artist on the main actor for each notification.
- `RemoteBrowserView.swift:205`, `:428-430`: `stats(forProvider:pathPrefix:)` on the main actor, a `LIKE` scan (01 #9).
- `FixedPlaylistView.swift:30-32`: a list query per notification.
- `FlaggedItemsView.swift:111`, `:201-208`: a detached whole-library `flaggedItems()` per notification. Runs aren't cancelled, so they overlap and finish out of order. A stale load can overwrite a newer one.
- Home, AlbumDetail, EpisodeDetailsPane, PlaybackEngine and CarPlay already debounce.
- Scenario: a drain with concurrency 8 finishes several tag reads a second. `LibraryNames` alone re-reads two whole tables on the main thread each time.
- Fix: post `libraryDidChange` once per drain pass, or through a 400 ms coalescer in one place, instead of per job. At minimum, give the four observers the existing `refreshSoon` pattern.

**10. `SourceRefresh` sends one HEAD and does two DB reads per episode, one at a time.**
`SourceRefresh.swift:21-36`
- An album page's refresh over 200 episodes makes 200 serial `metadata` requests, 200 `trackStore.find` calls and 200 `copies.find` calls.
- Fix: load tracks and copies with one `IN` query each. Then list each affected folder once (`listFiles(inFolder:)`) and match in memory, the rule CLAUDE.md sets for exactly this case. Fall back to HEAD only for single episodes.

**11. PLAUSIBLE: a job that crashes the app is requeued and run first thing on every launch.**
`SyncQueueManager.swift:58-62`; `SyncJobStore.swift:122-131`, `:226-233`
- `requeueOrphanedRunning` and `takeOrphanedListings` → `resumeInterruptedListings` restart whatever was running, immediately, with no attempt count.
- Scenario: a malformed file that crashes AVFoundation during `asset.load`, or a listing that runs out of memory on a huge bucket, crashes the app at every launch.
- No specific crash trigger was found in scope.
- Fix: increment `attempts` when a job is claimed. Requeue only rows below 2 attempts, and mark the rest failed with "Stopped the app last time".

**12. PLAUSIBLE: a failed `registerListed` is swallowed, and the pass still reports "Up to date".**
`Sync.swift:181`, `:194`, `:200`
- `(try? registerListed(...)) ?? 0` loses the error. The whole batch is one transaction, so one bad row (for example a unique-index conflict on `idx_tracks_provider_path` from a `tracks` row with no matching `trackFiles` row, or a full disk) rolls back every new file.
- `lastSyncedAt` is then updated, the listing row is marked done, and `summary` says "Up to date — N files, nothing new". The same thing happens on every later pass.
- Fix: let the error propagate, so the listing row is marked failed and the error is shown. Alternatively, skip and record the bad row, and commit the rest.

## Improvements (P3)

- Any `enqueue` error, a DB error included, is reported as hitting the queue limit (`catch { stoppedAtQueueLimit = true }`). Catch `SyncQueuePolicy.FullError` only and rethrow the rest. `Sync.swift:173-177`
- For YouTube-named files, `try? enqueueImport` swallows `FullError` without setting `stoppedAtQueueLimit`, so no top-up is scheduled for them. `Sync.swift:168`
- A copy that changed in place keeps its old title, duration and year. `refreshCopy` updates only size, hash and date, then recomputes `fingerprint` from the new size and the old duration. Set `needsTags` on a hash change. `Sync.swift:276-283`; `TrackStore.swift:312-328`
- Pause stops only the enqueue loop. The listing, `ArtworkSidecar.adopt` and `YouTubeTranscripts.adopt` carry on downloading. When a pass stops for pause, it still writes `lastSyncedAt`, so the scheduler waits a full interval before retrying. `Sync.swift:160`, `:189-194`
- `SyncScheduler.stop()` runs on `.inactive` as well as `.background`, so pulling down Notification Center cancels an in-flight scheduled listing. URLSession throws, and the pass is recorded as "The listing didn't finish." `SyncEngine` has no `Task.isCancelled` checks of its own. `EarToListenApp.swift:53-54`; `SyncScheduler.swift:31-35`
- `drain()` can exit with work pending. Jobs queued while `topUp()` is suspended get no wake-up, because `startDraining` does nothing while `isDraining` is set. When `topUp` then returns false, the loop breaks without checking `hasPending` again. Check it once more before `break`. `SyncQueueManager.swift:201-203`
- `clearQueue` deletes running rows, so the workers' `markDone`/`markFailed` silently find nothing. The next `fillTagReads` then refills the queue straight away with 100 tag reads, so "Clear" doesn't stay cleared. Failed readTags rows are dropped too, which makes those tracks eligible again. `SyncJobStore.swift:258-260`; `SyncQueueManager.swift:157-161`
- An upload job requeued after a crash, or retried after a lost response, finds its own completed object, and the never-overwrite check refuses it ("already exists"). The job fails permanently even though the file is in the bucket. Treat "exists with the same size" as uploaded. `EpisodeUpload.swift:95-97`; `SyncJobStore.swift:226-233`
- Retrying a listing (`retry(_:)`), `resumeInterruptedListings` and the scheduler all `try?` the sync and set no `notice`, so a failure shows only as another failed row. `SyncQueueManager.swift:77-82`, `:171-174`
- No progress is reported during the listing itself. A 20k-object bucket shows "Listing X" for the whole paging loop. Report pages or file counts through `markStage`/`displayName`. `Sync.swift:135`
- Every job writes its stage two or three times (`markStage` plus a notification), even when the stage lasts milliseconds (`.saving`). Keep the stage in memory, or write only stages that last long. `Sync.swift:213-215`, `:265-269`
- The `hasChanged` doc comment sits on `enqueueImport`. `Sync.swift:351-355`
- `TrackStore.deleteLost()` has no callers. `TrackStore.swift:799-808`

Out of scope here but flagged for step 07: `YouTubeTranscripts.adopt` re-downloads, on every sync, any transcript that parses to zero segments (`YouTubeTranscripts.swift:41-53`).

## Test gaps

- Sync over an empty or much shorter listing against a populated source. It must not mass-mark lost (#1).
- Two overlapping `sync` calls for one provider, and an upload job finishing between `listFiles` and `markLost`. The fresh copy must stay live (#2).
- Drain with the provider failing every `streamURL` or asset load. It must not burn through the whole `needsTags` backlog, and failed jobs must come back once the connection does (#3).
- A bucket with more than `capacity` lost files coming back. Count listings and transactions (#4).
- A same-bucket rename with an ETag present. It must re-link without a tag read (#6).
- Scheduler with a failing provider. No new failed row per poll (#5).
- `drain()` exit with a job enqueued during `topUp` (P3).
