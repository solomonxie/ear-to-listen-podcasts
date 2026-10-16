# Code review summary

Static review of `dc530fa`, steps 01–15. Effort: **S** under half a day, **M** 1–2 days, **L** 3+ days.

## 1. Totals

| Step | P0 | P1 | P2 | P3 |
|---|---|---|---|---|
| [01 DB](01-db.md) | 1 | 3 | 11 | 16 |
| [02 Playback](02-playback.md) | 0 | 5 | 6 | 14 |
| [03 Providers](03-providers.md) | 0 | 5 | 2 | 16 |
| [04 Sync](04-sync.md) | 0 | 3 | 9 | 13 |
| [05 Transcription](05-transcription.md) | 0 | 6 | 13 | 20 |
| [06 AI](06-ai.md) | 0 | 4 | 7 | 18 |
| [07 Library](07-library.md) | 0 | 1 | 8 | 11 |
| [08 Backup](08-backup.md) | 1 | 5 | 9 | 12 |
| [09 Importers](09-importers.md) | 0 | 0 | 2 | 9 |
| [10 Player](10-player.md) | 1 | 5 | 7 | 14 |
| [11 Home](11-home.md) | 0 | 3 | 18 | 16 |
| [12 Settings](12-settings.md) | 0 | 3 | 11 | 18 |
| [13 App/CarPlay](13-app-carplay.md) | 2 | 0 | 4 | 12 |
| [14 Build](14-build.md) | 0 | 1 | 1 | 10 |
| [15 Tests](15-tests.md) | 0 | 2 | 8 | 6 |
| **Total** | **5** | **46** | **116** | **205** |

Grand total: 372 as reported. About 5 are cross-step duplicates (10 P1#1 = 01 #3; 07 zip P3 = 08 #2; 15's two P1s are the test side of 04 #1 and 01 #1), so about 367 are unique.

## 2. Fix before resubmission

**P0**
- [ ] Migrations v31/v32 decode today's `Track`/`TrackFile`, so every pre-v32 install with episodes crashes on each launch, and `try!` makes it a loop. `Migrations.swift:544`, `:581-586`; `DatabaseManager.swift:20-21` ([01](01-db.md) #1). **M**
- [ ] A merge restore re-applies after every sync for up to 30 days. It reverts renames, favourites, bookmarks and listened marks, and clears notes. `BackupService.swift:234-288`; `PendingRestore.swift:32-43` ([08](08-backup.md) #1). **L**
- [ ] The Edit Episode sheet retargets on auto-advance. Save renames B as A, Cancel deletes A's artwork, and Delete removes B. `EpisodeDetailsPane.swift:54`, `:97` ([10](10-player.md) P0 #1). **S**
- [ ] The CarPlay sink runs `MainActor.assumeIsolated` on the `libraryDidChange` that sync posts off main, so any import crashes the app while it is connected (CARPLAY=1 TestFlight builds). `CarPlayController.swift:58` ([13](13-app-carplay.md) #1). **S**
- [ ] CarPlay pushes Now Playing while it is already on the stack, and depth is unbounded, so it can raise an exception while driving (PLAUSIBLE). `CarPlayController.swift:301-304` ([13](13-app-carplay.md) #2). **S**

**P1: rejection risk**
- [ ] No `PrivacyInfo.xcprivacy`, but the app uses UserDefaults and file timestamps (ITMS-91053). `project.yml:17-31`, `:124-127` ([14](14-build.md) #1). **S**
- [ ] (P2, PLAUSIBLE) China gating uses the device region until StoreKit answers, so a CN storefront with a non-CN region sees OpenAI and Whisper. Fail closed. `AppStorefront.swift:27-36` ([06](06-ai.md) #10). **S**

**P1: security**
- [ ] `unarchive` writes zip entry names unchecked, so `artwork/../…` can overwrite any sandbox file, including the live DB. `BackupService.swift:219-223` ([08](08-backup.md) #2). **S**

**P1: data loss and overwrites**
- [ ] A failed HEAD (timeout, 403, 5xx) counts as "key is free", so `uploadEpisode` overwrites audio. `Provider.swift:153-156` ([03](03-providers.md) #2). **S**
- [ ] S3 keys drop empty segments, so a DELETE of `shows//ep.mp3` deletes `shows/ep.mp3`. `S3RestClient.swift:19` ([03](03-providers.md) #3). **S**
- [ ] An empty or short listing marks the whole source lost, and Flagged then offers "Delete record". `Sync.swift:135`, `:193` ([04](04-sync.md) #1). **M**
- [ ] Overlapping passes per provider use a stale listing and mark fresh uploads lost. `SyncQueueManager.swift:120-130`; `Sync.swift:135-193` ([04](04-sync.md) #2). **M**
- [ ] `saveEdit` writes the whole stale `Track`, which reverts progress, favourite, summary, lost state and the picked language. `TrackStore.swift:252-256` ([01](01-db.md) #3, [10](10-player.md) P1 #1). **S**
- [ ] `TrackMerge` with 3+ copies folds onto the original keeper, so earlier folds' marks are lost. `TrackMerge.swift:19-24` ([01](01-db.md) #2). **S**
- [ ] `DuplicateTitles` renumbers real tag-carried "(n)" titles. `DuplicateTitles.swift:47-77` ([07](07-library.md) #1). **S**
- [ ] (PLAUSIBLE) The undo snapshot is a raw copy of a live rollback-journal DB, so it can be torn. `DatabaseManager.swift:49-62`; `LocalBackups.swift:76-87` ([01](01-db.md) #4). **S**
- [ ] Restore has no rollback: a part-way failure leaves the library half-merged with no undo offered. `DatasetRestore.swift:54-64` ([08](08-backup.md) #3). **M**
- [ ] A restore onto a library with no tracks swaps the whole DB, which wipes sources and AI keys. `DatasetRestore.swift:60`, `:72-90` ([08](08-backup.md) #5). **S**
- [ ] The post-restore iCloud backup overwrites today's source archive and drops its change log. `AutoBackup.swift:47-52` ([08](08-backup.md) #6). **M**
- [ ] Albums and most speaker fields aren't archived, so a reinstall loses them. `Snapshot.swift:56-63`; `BackupService.swift:79-87` ([08](08-backup.md) #4). **M**
- [ ] An import done in demo mode leaves an Undo that later puts the sample library over the real one. `BackupSettingsView.swift:94-143`; `DatasetRestore.swift:94-103` ([12](12-settings.md) #1). **S**
- [ ] Long-press Delete removes a source with no confirmation. `SourcesSectionView.swift:87-93` ([12](12-settings.md) #2). **S**
- [ ] Cancelling an add sheet mid-test still saves the bucket or key and queues the bucket. `AddCloudSourceView.swift:129-137`; `AddAiKeyView.swift:82-88` ([12](12-settings.md) #3). **S**
- [ ] ✨ writes A's suggestion onto B after a track change, then pays for B's summary. `EpisodeDetailsPane.swift:416-438` ([10](10-player.md) P1 #2). **S**
- [ ] Album Analyze applies by a recomputed index, so titles land on the wrong episodes. `AlbumAnalysisView.swift:155-171` ([06](06-ai.md) #2). **S**
- [ ] Opening an album page saves it and stamps it edited, which reorders Home and blocks cover adoption. `AlbumDetailView.swift:229-230`, `:366-405` ([11](11-home.md) #1). **S**
- [ ] Upload writes a language transcript over the untagged (other-language) sidecar. `TranscriptRunner.swift:131-132`, `:320` ([05](05-transcription.md) #4). **M**
- [ ] A failed or slow load keeps the old audio and saves A's position onto B. `PlaybackEngine.swift:143-161`, `:494-519` ([02](02-playback.md) #2). **S**
- [ ] (PLAUSIBLE) A malformed GCS bucket name crashes "Test connection" on a force-unwrap. `GoogleCloudStorageProvider.swift:46` ([03](03-providers.md) #5). **S**

Ride-alongs (P2/P3 crashes or loss): a sidecar time over `Int.max` traps (05 #19); `ZipArchive.write` traps past 65,535 entries (08 P3); deleting a speaker deletes shared albums (07 #9); artwork upload overwrites the listener's `cover.jpg` (07 #6); migrations on main hit the watchdog (13 P2 #2).

## 3. Fix order

Batches 1–9 are the resubmission set. Each line ends with its tests ([15](15-tests.md)). **Locks bug** marks an existing test that asserts the bug and must change with the fix.

- [ ] **Batch 1: launch safety.** Rewrite v31/v32 as raw SQL with explicit child deletes. Replace both `try!` with a caught error, a moved-aside file and an error screen. Optionally open and migrate off main behind a gate (13 P2 #2). Tests: **T1** (`upTo: v30` with rows, FK check) plus a `Tests/Fixtures/v30.sqlite` (15 P1 #2).
- [ ] **Batch 2: App Store hygiene.** App and extension `PrivacyInfo.xcprivacy` (UserDefaults `CA92.1`/`1C8F.1`, FileTimestamp `C617.1`/`3B52.1`; extension `1C8F.1`). Gitignore `*.p8`, `private_keys/`, `.env` (14 P2 #1). One `MARKETING_VERSION` (14 P3 #5). Fail-closed China gating (06 #10). Tests: `make check` manifest lint; `isChina` with no cached storefront.
- [ ] **Batch 3: CarPlay.** Post `libraryDidChange` through one `@MainActor` coalescing helper (also starts theme 5), plus `.receive(on: .main)` in the controller. Pop to Now Playing if it is on the stack. Tests: **T8** (fails today), `CarNavigation` depth ≤ 5.
- [ ] **Batch 4: store write safety.** `saveEdit` as a targeted UPDATE inside one write (01 #3, 10 P1 #1). Thread `kept` through `TrackMerge` and re-fetch twins (01 #2). `DuplicateTitles` groups by original title in `EpisodeOrder` order (07 #1, #3). Snapshot via `dbQueue.backup(to:)` or `VACUUM INTO` (01 #4). Tests: **T2**, **T6**, `testSaveEditDoesNotRevertLanguage`, `testTagNumberedTitlesAreNotRenumbered`. Locks bug: `DuplicateTitlesTests.swift:58-71` (15 P2 #3). Also fix `SameFileTests.swift:264` hash sizes (15 P3 #5).
- [ ] **Batch 5: stale captures in screens.** `.sheet(item:)` for Edit and AddToPlaylist (10 P0). Capture the id across `await` in `suggest`/`analyze`, compute readiness from `playingTrack` (10 P1 #2, #3). Reset edit and selection state on track change (P1 #4). `loadedID` guard (P2 #7). Album analysis applies by id (06 #2). Dirty-check album and speaker saves (11 #1, P2 #9). Tests: UI test for the sheet across auto-advance, `testSuggestionsLandByEpisodeIDNotPosition`, `testOpeningAnAlbumDoesNotStampItEdited` (extract the models first).
- [ ] **Batch 6: sync must not lose episodes.** Local listing and the XML parsers throw on nil, error, a bad page or truncation (03 P3). Plausibility guard before `markLost`: empty or >20% held back and the user asked (04 #1). One in-flight pass per provider; `markLost` skips copies added after the listing started (04 #2). Propagate `registerListed` errors (04 #12). Tests: **T4**, `testACopyAddedAfterTheListingIsNotMarkedLost`, scripted `Result` fakes (15 P2 #7). Locks bug: `SyncEngineTests.swift:131-149` (15 P1 #1); rewrite it as two files to one.
- [ ] **Batch 7: provider writes.** Treat only an explicit 404 as free, or use conditional writes (`If-None-Match: *`, `ifGenerationMatch=0`, `.withoutOverwriting`) (03 #2; also the 04 P3 upload requeue). `RFC3986.encodePath` for S3 keys and canonical URIs (03 #3). Azure signs `percentEncodedPath` (03 #1). Path-style region detection for dotted buckets (03 #4). Remove the GCS and S3 `!` (03 #5). Tests: **T5**, `testAFailedExistenceCheckIsNotTreatedAsFree`, `testAKeyWithAnEmptySegmentKeepsIt`, dotted-bucket detection, AWS known-answer SigV4 vectors (15 P2 #4).
- [ ] **Batch 8a: restore safety.** Zip names limited to one component, decode before writing images (08 #2). Refuse when a safety copy fails; merge into a staged DB then `replaceContents` (08 #3). Count providers and keys in `hasALibrary` (08 #5). Fence Import and Undo in demo (12 #1). Confirm Undo and migrate before the swap (08 #14). Tests: **T7**, `testAFailedApplyLeavesTheLibraryUntouched`, `DatasetRestoreTests` (seam), `testImportIsRefusedInDemoMode`. Point the image stores at a temp dir (15 P2 #5).
- [ ] **Batch 8b: merge semantics.** `apply` is fill-only or newer-wins and never clears; re-apply only unmatched entries and stop counting ones a full listing ruled out (08 #1). `AlbumEntry` and the missing artist and episode fields, version bump, log album writes (08 #4). No backup right after a restore, and never overwrite another install's or a newer archive (08 #6). Keep orphan paths (08 #13). Gregorian names (08 #7). Tests: **T3**, `testAlbumAndSpeakerProfilesRoundTrip`, `testRestoreDoesNotRewriteTheArchiveItCameFrom`, Japanese and Buddhist name tests. Locks bug: the "idempotent" tests `BackupServiceTests.swift:174-187`, `:322-340` and `CloudBackupTests.swift:45-66` never edit between applies (15 P2 #1); add edits.
- [ ] **Batch 9: settings guards.** Confirm long-press Delete (12 #2). Cancel the add task and check `isCancelled` before saving (12 #3). Re-entry guard and progress for Remove All (12 P2 #10). Tests: `testCancelDuringValidationSavesNothing`.
- [ ] **Batch 10: playback state machine.** Load generation token (02 #1). Stop the old item and gate `persistProgress` on the loaded id (02 #2). KVO `timeControlStatus`, interruption and route change (02 #3). Retry from the playhead (02 #4). Same-id play resumes (02 #5). Toggle and change-position commands (02 #11). `.spokenAudio` and flush on background (P3). Tests: the five `PlaybackEngineTests` behind a `PlayerDriving` seam.
- [ ] **Batch 11: transcription.** Start a pass when the sidecar found nothing, and define "Replace" (05 #1). Auto-resume only on transient errors, capped (05 #2). Reset `isUploading` (05 #3). No-speech error maps to `[]` (05 #6). Merge across silence markers (05 #5; same for the bookmark stepper, 10 P1 #5). Store `[]` for "no sidecar", which removes the 5-path probe CLAUDE.md names (05 #13). Clamp sidecar times (05 #19). Tests: the 05 gap list, `testMergeAcrossASilenceMarkerJoinsTheTwoLines` (15 P2 #2), `BookmarkStepperTests`.
- [ ] **Batch 12: AI correctness.** Per-pass `maxTokens` and a "cut off" error (06 #1). Context-aware budgets or a Kimi 32k default (06 #3). `max_completion_tokens` for OpenAI and a current Gemini default (06 #4). Cancellation is not a key failure (06 #5). Decode vendor error bodies (06 #11). Tests: `AiRouterTests`, `OpenAIChatClientTests`, retired-model list (15 P3 #6).
- [ ] **Batch 13: queue resilience and coalescing.** Network-gated drain, `attempts`/`nextAttemptAt` with backoff, Retry all (04 #3, #11). Back off failing listings (04 #5). Bulk-handle lost and changed copies in the listing pass (04 #4), relink before `markLost` (04 #6). One `libraryDidChange` per drain (04 #9). One ChangeLog entry per batch (01 #12). Tests: real `drain` behind a seam, `testOfflineDrainClaimsNothing` (15 P2 #8).
- [ ] **Batch 14: main actor and indexes.** `PlaybackClock` split (10 P2 #1, 13 P3). `DatabasePool` (01 #8). Indexes for the lost hash, `trackFiles.filePath`, `albumID WHERE isLost` and `syncJobs(status, createdAt)` (01 #6, #7, #11, P3). Detached page loads (11 P2 #11, 06 #7, 08 #8, 12 P2 #1, #11). Search staleness, folding, ranking and in-flight state (11 #3, P2 #1–#5). Plain-text transcript search (01 #10).
- [ ] **Batch 15: size.** See section 5. Delete `MatcherTests` and the `EarToListenTests` placeholder along with the code.

## 4. Cross-cutting themes

**1. Stale capture across an episode change.**
- Edit sheet retargets (10 P0); ✨ onto B (10 P1 #2); readiness for A (P1 #3); late `load()` (P2 #7).
- Overlapping loads, an old position saved onto a new id, stale-`positionMs` retries (02 #1, #2, #4, #5).
- `isUploading` stuck, pass killed on auto-advance (05 #3, #15); album apply by index (06 #2).
- Superseded search lands (11 #3); no generation guard on Home or car refresh (11 P3, 13 P3).
- Pattern: `let id` before every `await` and drop the result if `current?.id != id`; generation token per loader; `.sheet(item:)`; `.task(id:)` keyed on id plus revision.

**2. Whole-row writes and unrequested writes.**
- `saveEdit` saves every column (01 #3, 10 P1 #1); `TrackMerge` folds onto a stale keeper (01 #2).
- Restore `apply` overwrites and clears (08 #1); transcript read-modify-write spans two transactions (01 #15).
- Album and speaker pages save on open and blur (11 #1, P2 #9); AI model saved per keystroke (12 P2 #2).
- Pattern: targeted `UPDATE` of the changed columns, re-read inside the same write; views dirty-check against the seeded snapshot; merges fill or newer-wins and never clear.

**3. Absence or failure read as fact (swallowed `try?`).**
- HEAD failure is "free" (03 #2); empty listing is "gone" (04 #1); parse failure is the last page (03 P3).
- `registerListed` failure reports "Up to date" (04 #12); `downloadBackup` errors read as "no backup" (03 P3); a transcript read failure drops it from the backup (08 #10).
- Optional safety copies (08 #3); a failed local backup marks the day done (08 P3); saves dismiss on failure (10 P3, 11 P3); the Share extension says "Added" blindly (09 #2).
- Pattern: typed errors, where only an explicit not-found means absent; plausibility guards before destructive bulk steps; otherwise a visible error state.

**4. Per-item I/O and full scans.**
- The 5-path sidecar probe is back (05 #13); `cachedSize` per track (02 #9); HEAD per episode (04 #10).
- `ArtworkSidecar.adopt` reads per copy (04 #7); play queue reads per file (12 P2 #5); `TermDetailView` per album (11 P2 #11); backup per transcript (08 #10).
- Unread FTS (01 #5); relink scan per file (01 #6); `foldArrival` scan (01 #7); `find(filePath:)` per restore entry (01 #11).
- AI call per imported file (06 #6); `episode-001.mp3` taken for YouTube, so one job per file (07 #2).
- Pattern: one listing or one `IN` query into a dictionary, then match in memory; add the four indexes; batch the AI; store "checked, none" apart from "unknown".

**5. Bursts not coalesced.**
- `libraryDidChange` per tag read with four undebounced observers (04 #9); the car rebuilds on every play/pause (13 P2 #1).
- `setListened` writes one ChangeLog per id (01 #12); `ChangeLog.record` posts per row in a restore (08 P3).
- Queue tick re-renders every browser level (12 P2 #4); uncancelled transcript scans per keystroke (11 P2 #5).
- Pattern: one `@MainActor` coalescing notifier (about 400 ms) as the only poster; post per drain or batch; update items in place.

**6. Main-actor work and over-observation.**
- Whole player re-renders every 0.5 s (10 P2 #1); App and `ContentView` observe the whole engine (13 P3).
- Progress writes and the cover decode on main (02 #6); every transcript window encoded on main (05 #12); restore, export and demo swap on main (08 #8, 12 P2 #1); source delete on main (12 P2 #11).
- DB migrate before the first frame (13 P2 #2); list artwork decoded on main with no cache (13 P2 #3); `DatabaseQueue` makes UI reads wait behind sync (01 #8).
- Pattern: a `PlaybackClock` observed only by leaf views; `DatabasePool`; one detached read per page returning a `Sendable` struct; off-main thumbnails in an `NSCache`.

**7. Unbounded retries with no transient/permanent split.**
- Failed jobs never retry, crashed jobs retry forever (04 #3, #11); a failing listing re-runs every 60 s (04 #5).
- Transcription auto-resumes on permanent errors (05 #2); oEmbed 4xx and bad YouTube transcripts retried forever (07 #4, #7).
- A broken backup destination rebuilds the archive on every leave (08 #12); `run_until_done.sh` never stops (14 P3 #10).
- Pattern: `attempts` and `nextAttemptAt` with backoff; retry transport errors, 429 and 5xx; surface auth, 4xx and missing models once.

**8. Tests that can't see the bugs.**
- DBs only migrated from empty; fakes only answer found or not found; the real drain is replaced (15 P1 #2, P2 #7, #8).
- Two tests assert bugs (15 P1 #1, P2 #3); app-hosted tests write into real containers and the keychain (15 P2 #5).
- Pattern: fixture DBs per shipped schema; scripted `Result` fakes; injected DB, monitor and image directory; tests that put an edit between two passes.

## 5. Size wins

- **Spotify and `TrackMatcher`**: delete `Sources/Importers/`, `MatcherTests`, the launch registration and the Settings `spotifyClientID` members (09 #1). This also removes a keychain read that can break Settings `load()`.
- **`trackSearchIndex` FTS5**: never read. Drop it in v47 and remove the writes and `TrackStore.search` (01 #5). Also a large O(N²) write win.
- **Dead columns**: `tracks.prefersVoice` and `isDemo` (01 P3).
- **Dead files and members**:
  - `EpisodeLanguageField.swift` (93 lines) and the old inline form in `EpisodeDetailsPane` (10 P3).
  - `TranscriptCoverage.isWorthFinishing`, `AppleSpeechTranscriber.isSupported`/`lines(from:)`, `AudioWindowFile.localURL`, `OpenAIWhisperTranscriber.hasKey` (05 P3).
  - `YouTubeCatalog.State`/`state(dbQueue:)`, `ImageFileStore.save(_ data:)`, the `Track.youTubeID` alias (07 P3).
  - `AutoBackup.backUpNow`, `LocalBackups.archives()`/`databaseCopies()`, test-only `BackupArchiveName.newest` (08 P3); `TrackStore.deleteLost` (04 P3).
  - `SettingsViewModel.testConnection`/`testResults`/`toggleActive`/`hasActiveRemoteProvider`/`setAiKeyModel`, and `RemoteBrowserView.syncNow`/`syncMessage`/`isSyncing`/`frequency` (12 P3). Wire a "Test" item or delete them.
  - `sectionTitle()` and `UnfoldingPicker.valueAlignment` (13 P3); the `EarToListenTests` placeholder (15 P3 #1).
- **CarPlay in Release**: code, framework and scene ship without the entitlement. Fence them behind a compilation condition (13 P3).
- **Build**: `-Osize` and `DEAD_CODE_STRIPPING: YES` for Release (14 P3 #2); measure the stripped archive, not `make size` (14 P3 #3); pin GRDB (14 P3 #1).
- **On-device disk**: sweep orphaned artwork and photos (07 #8); stop starting a background download on every play (02 #7).

## 6. What's solid

- Secrets: none in git history (263 commits) or in logs, errors or backups; keys stay in the Keychain.
- Signing: SigV4, Azure SAS and GCS V4 are correct, and paging is correct on all three clouds.
- China gating holds at every AI call site; only the storefront fallback is weak.
- iOS 27 scenes are correct, with no private API; Debug, demo and screenshot code is gated; GRDB is the only dependency.
- Sync design: one listing, one `byPath`, one `registerListed` transaction, claim-in-transaction dequeue.
- Library search folds once, runs off main and renders lazily; transcript rows are lazy and `.equatable()`, with stable `ForEach` IDs.
- ImageIO thumbnails for artwork and CarPlay; strict YouTube ID parsing; the share extension is small.
- Transcription internals: window plan, silence bookkeeping, recognizer gate and watchdog, and "Upload is the only write".
- `replaceContents` is a real atomic swap, and the empty-archive guard works.
